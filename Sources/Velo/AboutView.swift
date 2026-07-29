import SwiftUI

/// Simple modal sheet showing app information and third-party licenses.
struct AboutView: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("About")
                    .font(Velo.display(24))
                    .foregroundStyle(.white)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.5))
                        .font(.title2)
                }
                .buttonStyle(.plain)
            }

            Text("© 2026 Rory Gallagher. All rights reserved.")
                .font(Velo.light(14))
                .foregroundStyle(.white.opacity(0.7))

            Link("https://github.com/rorygallagher2024/velo-visualiser-mac",
                 destination: URL(string: "https://github.com/rorygallagher2024/velo-visualiser-mac")!)
                .font(Velo.light(14))
                .foregroundStyle(.blue)

            Divider().overlay(.white.opacity(0.2))

            Text("Third-Party Licenses")
                .font(Velo.display(16))
                .foregroundStyle(.white)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("**Satoshi & Clash Display Fonts**\nCopyright © Indian Type Foundry. Licensed under the Fontshare Free Font License.")
                        .font(Velo.light(12))
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(30)
        .frame(width: 450, height: 400)
        .background(Color.black)
    }
}

/// Simple modal sheet showing the privacy policy.
struct PrivacyView: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Privacy Policy")
                    .font(Velo.display(24))
                    .foregroundStyle(.white)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.5))
                        .font(.title2)
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Last Updated: July 2026")
                        .font(Velo.light(14))
                        .foregroundStyle(.white.opacity(0.6))

                    Text("Velo Visualiser (\"we\", \"our\", or \"us\") is committed to protecting your privacy. This Privacy Policy explains how we handle data when you use our application.")
                        .font(Velo.light(14))
                        .foregroundStyle(.white.opacity(0.8))

                    Text("**1. Information We Collect**")
                        .font(Velo.display(16))
                        .foregroundStyle(.white)

                    Text("**Audio Data (Microphone & System Audio)**\n• **What we collect:** The app accesses your Mac's microphone or system audio (via loopback) to generate real-time visualisations.\n• **How we use it:** Audio data is processed **locally and in real-time** on your machine. We use this data only to calculate frequency bands and waveforms for visual effects.\n• **Storage and Transmission:** We **do not record, store, or transmit** any audio data. The raw PCM data exists only in temporary volatile memory (RAM) for the duration of the processing (typically under 10ms) and is immediately overwritten.")
                        .font(Velo.light(14))
                        .foregroundStyle(.white.opacity(0.8))

                    Text("**Device Information**\n• The app queries your device's display capabilities (such as HDR support and refresh rate) to optimize Metal rendering. This information is not collected or transmitted.")
                        .font(Velo.light(14))
                        .foregroundStyle(.white.opacity(0.8))

                    Text("**2. Data Safety**")
                        .font(Velo.display(16))
                        .foregroundStyle(.white)
                        
                    Text("Velo Visualiser does not collect, share, or sell any personal data. It is a utility tool designed to operate entirely on-device with zero network requests.")
                        .font(Velo.light(14))
                        .foregroundStyle(.white.opacity(0.8))

                    Text("**3. Contact Us**")
                        .font(Velo.display(16))
                        .foregroundStyle(.white)
                        
                    Text("If you have any questions about this Privacy Policy, please contact us via our GitHub repository.")
                        .font(Velo.light(14))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(30)
        .frame(width: 500, height: 600)
        .background(Color.black)
    }
}
