// Prefix header — replaces Syphon_Prefix.pch for the SPM build.
// Guard ObjC imports so SyphonDispatch.c (plain C) compiles too.
#ifdef __OBJC__
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <CoreVideo/CoreVideo.h>
#endif

#ifdef DEBUG
#define SYPHONLOG(format, ...) NSLog(@"SYPHON: %@", [NSString stringWithFormat:format, ##__VA_ARGS__])
#else
#define SYPHONLOG(format, ...)
#endif
