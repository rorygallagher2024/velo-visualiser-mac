import AVFoundation
import Foundation

/// Local file playback using the same AVAudioSourceNode pattern as ToneGenerator.
///
/// Decodes the entire file into stereo float buffers, then feeds them through
/// an AVAudioSourceNode whose render callback fires at the audio render rate —
/// ensuring the AudioEngine ring is written at the same cadence as AUHAL mic
/// capture, so visuals update every frame instead of in infrequent bursts.
///
/// Follows the single-producer contract: stops AUHAL capture before starting,
/// resumes it on stop. Stereo is preserved end-to-end for XY scopes.
final class FilePlayer: @unchecked Sendable {

    private var avEngine: AVAudioEngine?
    private weak var audioEngine: AudioEngine?

    private(set) var file: AVAudioFile?
    private(set) var isPlaying = false {
        didSet { if isPlaying != oldValue { DispatchQueue.main.async { self.onPlaybackStateChange?() } } }
    }
    private(set) var isPaused = false {
        didSet { if isPaused != oldValue { DispatchQueue.main.async { self.onPlaybackStateChange?() } } }
    }
    nonisolated(unsafe) var looping = false

    var onPlaybackStateChange: (() -> Void)?

    private var leftSamples: [Float] = []
    private var rightSamples: [Float] = []
    private var totalFrames = 0
    private var fileSampleRate: Double = 48_000
    nonisolated(unsafe) private var readPosition = 0
    nonisolated(unsafe) private var endNotified = false

    var duration: TimeInterval {
        totalFrames > 0 ? Double(totalFrames) / fileSampleRate : 0
    }

    var currentTime: TimeInterval {
        guard totalFrames > 0 else { return 0 }
        return Double(min(readPosition, totalFrames)) / fileSampleRate
    }

    var fileName: String? {
        file?.url.deletingPathExtension().lastPathComponent
    }

    func play(url: URL, audioEngine: AudioEngine) {
        stop()
        self.audioEngine = audioEngine

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            VeloLog.write("file", "failed to open \(url.lastPathComponent): \(error)")
            return
        }
        file = audioFile
        fileSampleRate = audioFile.processingFormat.sampleRate

        let fileFrames = Int(audioFile.length)
        guard fileFrames > 0 else {
            VeloLog.write("file", "empty file: \(url.lastPathComponent)")
            return
        }

        let readFormat = audioFile.processingFormat
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: readFormat,
            frameCapacity: AVAudioFrameCount(fileFrames)
        ) else {
            VeloLog.write("file", "failed to allocate decode buffer")
            return
        }
        do {
            try audioFile.read(into: buffer)
        } catch {
            VeloLog.write("file", "failed to decode: \(error)")
            return
        }

        let frames = Int(buffer.frameLength)
        guard let channelData = buffer.floatChannelData, frames > 0 else {
            VeloLog.write("file", "no audio data after decode")
            return
        }

        leftSamples = Array(UnsafeBufferPointer(start: channelData[0], count: frames))
        if readFormat.channelCount >= 2 {
            rightSamples = Array(UnsafeBufferPointer(start: channelData[1], count: frames))
        } else {
            rightSamples = leftSamples
        }
        totalFrames = frames
        readPosition = 0
        endNotified = false

        audioEngine.stop()
        audioEngine.hasStereoSource = true
        audioEngine.activeSampleRate = fileSampleRate

        let engine = AVAudioEngine()
        let outFormat = AVAudioFormat(
            standardFormatWithSampleRate: fileSampleRate, channels: 2)!

        let sourceNode = AVAudioSourceNode(format: outFormat) {
            [weak self] _, _, frameCount, bufferListPtr -> OSStatus in
            guard let self, self.isPlaying else {
                let ablp = UnsafeMutableAudioBufferListPointer(bufferListPtr)
                for buf in ablp { if let d = buf.mData { memset(d, 0, Int(buf.mDataByteSize)) } }
                return noErr
            }
            return self.renderAudio(frameCount: Int(frameCount), bufferList: bufferListPtr)
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: outFormat)

        do {
            try engine.start()
        } catch {
            VeloLog.write("file", "engine start failed: \(error)")
            leftSamples = []; rightSamples = []
            totalFrames = 0
            audioEngine.start()
            return
        }

        avEngine = engine
        isPlaying = true
        isPaused = false
    }

    func pause() {
        guard isPlaying, !isPaused else { return }
        avEngine?.pause()
        isPaused = true
    }

    func resume() {
        guard isPlaying, isPaused else { return }
        do { try avEngine?.start() } catch {
            VeloLog.write("file", "resume failed: \(error)")
        }
        isPaused = false
    }

    func togglePlayPause() {
        if isPaused { resume() } else { pause() }
    }

    func stop() {
        isPlaying = false
        avEngine?.stop()
        avEngine = nil
        file = nil
        isPaused = false
        readPosition = 0
        totalFrames = 0
        endNotified = false
        leftSamples = []
        rightSamples = []
        if let engine = audioEngine {
            engine.hasStereoSource = false
            engine.activeSampleRate = 0
            engine.start()
            audioEngine = nil
        }
    }

    func seek(to time: TimeInterval) {
        guard isPlaying, totalFrames > 0 else { return }
        let frame = Int(time * fileSampleRate)
        readPosition = max(0, min(frame, totalFrames))
        endNotified = false
    }

    // MARK: - Render callback

    private func renderAudio(
        frameCount: Int, bufferList: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let ablp = UnsafeMutableAudioBufferListPointer(bufferList)
        guard let buf0 = ablp[0].mData?.assumingMemoryBound(to: Float.self) else {
            return noErr
        }
        let buf1: UnsafeMutablePointer<Float>
        if ablp.count > 1, let b = ablp[1].mData?.assumingMemoryBound(to: Float.self) {
            buf1 = b
        } else {
            buf1 = buf0
        }

        var pos = readPosition
        let total = totalFrames
        var written = 0

        while written < frameCount {
            if pos >= total {
                if looping {
                    pos = 0
                } else {
                    let remaining = frameCount - written
                    memset(buf0 + written, 0, remaining * MemoryLayout<Float>.stride)
                    memset(buf1 + written, 0, remaining * MemoryLayout<Float>.stride)
                    if !endNotified {
                        endNotified = true
                        DispatchQueue.main.async { [weak self] in self?.handleEnd() }
                    }
                    break
                }
            }

            let chunk = min(frameCount - written, total - pos)
            leftSamples.withUnsafeBufferPointer { left in
                rightSamples.withUnsafeBufferPointer { right in
                    memcpy(buf0 + written, left.baseAddress! + pos,
                           chunk * MemoryLayout<Float>.stride)
                    memcpy(buf1 + written, right.baseAddress! + pos,
                           chunk * MemoryLayout<Float>.stride)
                    audioEngine?.injectStereoSamples(
                        left: left.baseAddress! + pos,
                        right: right.baseAddress! + pos,
                        count: chunk)
                }
            }
            pos += chunk
            written += chunk
        }

        readPosition = pos
        return noErr
    }

    private func handleEnd() {
        guard isPlaying else { return }
        stop()
    }
}
