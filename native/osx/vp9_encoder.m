#import "vp9_encoder.h"
#import <QuartzCore/QuartzCore.h>

@implementation VP9Encoder

- (instancetype)initWithWidth:(int)width 
                       height:(int)height 
                      bitrate:(int)bitrate 
                    framerate:(int)framerate {
    self = [super init];
    if (self) {
        self.width = width;
        self.height = height;
        self.bitrate = bitrate;
        self.framerate = framerate;
        self.encodedData = [NSMutableData data];
        
        [self setupEncoder];
    }
    return self;
}

- (void)setupEncoder {
    OSStatus status;
    CMVideoCodecType codecType;
    
    // Check macOS version and try codecs in order of preference
    if (@available(macOS 13.0, *)) {
        // Try VP9 first
        codecType = kCMVideoCodecType_VP9;
        status = VTCompressionSessionCreate(
            kCFAllocatorDefault,
            self.width,
            self.height,
            codecType,
            NULL, NULL, NULL,
            compressionOutputCallback,
            (__bridge void *)self,
            &_compressionSession
        );
        
        if (status == noErr) {
            NSLog(@"✅ VP9 encoder initialized successfully");
        } else {
            NSLog(@"⚠️ VP9 not available (status: %d), trying HEVC...", status);
            codecType = 0; // Reset for fallback
        }
    } else {
        NSLog(@"⚠️ macOS < 13.0, VP9 not available");
        codecType = 0;
    }
    
    // Fallback to HEVC if VP9 failed or unavailable
    if (codecType == 0 || _compressionSession == NULL) {
        codecType = kCMVideoCodecType_HEVC;
        status = VTCompressionSessionCreate(
            kCFAllocatorDefault,
            self.width,
            self.height,
            codecType,
            NULL, NULL, NULL,
            compressionOutputCallback,
            (__bridge void *)self,
            &_compressionSession
        );
        
        if (status == noErr) {
            NSLog(@"✅ HEVC encoder initialized successfully");
        } else {
            // Final fallback to H.264
            NSLog(@"⚠️ HEVC not available (status: %d), trying H.264...", status);
            codecType = kCMVideoCodecType_H264;
            status = VTCompressionSessionCreate(
                kCFAllocatorDefault,
                self.width,
                self.height,
                codecType,
                NULL, NULL, NULL,
                compressionOutputCallback,
                (__bridge void *)self,
                &_compressionSession
            );
            
            if (status != noErr) {
                NSLog(@"❌ Failed to create any compression session! H.264 status: %d", status);
                return;
            }
            NSLog(@"✅ H.264 encoder initialized successfully");
        }
    }
    
    // Configure encoder properties only if session was created
    if (_compressionSession == NULL) {
        NSLog(@"❌ No compression session available!");
        return;
    }
    
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    
    // Set profile based on codec type
    if (codecType == kCMVideoCodecType_HEVC) {
        VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel);
    } else if (codecType == kCMVideoCodecType_H264) {
        VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel);
    }
    
    // Set bitrate
    int bitrateBps = self.bitrate;
    CFNumberRef bitrateRef = CFNumberCreate(NULL, kCFNumberIntType, &bitrateBps);
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_AverageBitRate, bitrateRef);
    CFRelease(bitrateRef);
    
    // Set framerate
    CFNumberRef framerateRef = CFNumberCreate(NULL, kCFNumberIntType, &_framerate);
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_ExpectedFrameRate, framerateRef);
    CFRelease(framerateRef);
    
    // Set keyframe interval (every 2 seconds)
    int keyframeInterval = self.framerate * 2;
    CFNumberRef keyframeIntervalRef = CFNumberCreate(NULL, kCFNumberIntType, &keyframeInterval);
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, keyframeIntervalRef);
    CFRelease(keyframeIntervalRef);
    
    // Enable B-frames for better compression
    VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanTrue);
    
    VTCompressionSessionPrepareToEncodeFrames(_compressionSession);
}

static void compressionOutputCallback(
    void *outputCallbackRefCon,
    void *sourceFrameRefCon,
    OSStatus status,
    VTEncodeInfoFlags infoFlags,
    CMSampleBufferRef sampleBuffer
) {
    if (status != noErr) {
        NSLog(@"❌ Encoding failed: %d", status);
        return;
    }
    
    if (!sampleBuffer) {
        return;
    }
    
    VP9Encoder *encoder = (__bridge VP9Encoder *)outputCallbackRefCon;
    
    // Get the encoded data
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!blockBuffer) {
        return;
    }
    
    size_t totalLength = 0;
    char *dataPointer = NULL;
    OSStatus result = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &totalLength, &dataPointer);
    
    if (result == noErr && dataPointer && totalLength > 0) {
        NSData *encodedFrame = [NSData dataWithBytes:dataPointer length:totalLength];
        
        // Check if this is a keyframe
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
        BOOL isKeyframe = NO;
        if (attachments && CFArrayGetCount(attachments) > 0) {
            CFDictionaryRef attachment = CFArrayGetValueAtIndex(attachments, 0);
            CFBooleanRef dependsOnOthers = CFDictionaryGetValue(attachment, kCMSampleAttachmentKey_DependsOnOthers);
            isKeyframe = (dependsOnOthers == kCFBooleanFalse);
        }
        
        // Call the callback on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            if (encoder.frameCallback) {
                encoder.frameCallback(encodedFrame);
            }
        });
        
        static int frameCount = 0;
        frameCount++;
        if (frameCount % 300 == 0) { // Every 10 seconds at 30fps
            NSLog(@"🎥 VP9/HEVC encoded %d frames, latest: %zu bytes %@", 
                  frameCount, encodedFrame.length, isKeyframe ? @"(keyframe)" : @"");
        }
    }
}

- (BOOL)encodeFrame:(CVPixelBufferRef)pixelBuffer {
    if (!_compressionSession || !pixelBuffer) {
        return NO;
    }
    
    CMTime presentationTimeStamp = CMTimeMake(CACurrentMediaTime() * 1000, 1000);
    CMTime duration = CMTimeMake(1, self.framerate);
    
    VTEncodeInfoFlags flags;
    OSStatus status = VTCompressionSessionEncodeFrame(
        _compressionSession,
        pixelBuffer,
        presentationTimeStamp,
        duration,
        NULL, // frame properties
        NULL, // source frame refcon
        &flags
    );
    
    return status == noErr;
}

- (void)setFrameCallback:(void (^)(NSData *encodedFrame))callback {
    self.frameCallback = callback;
}

- (void)forceKeyFrame {
    if (_compressionSession) {
        VTCompressionSessionCompleteFrames(_compressionSession, kCMTimeInvalid);
        
        // Force next frame to be keyframe
        CFDictionaryRef frameProperties = CFDictionaryCreate(
            NULL,
            (const void *[]){kVTEncodeFrameOptionKey_ForceKeyFrame},
            (const void *[]){kCFBooleanTrue},
            1,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks
        );
        
        // Store for next encode
        // Note: This would need to be passed to the next encodeFrame call
        CFRelease(frameProperties);
    }
}

- (void)dealloc {
    if (_compressionSession) {
        VTCompressionSessionInvalidate(_compressionSession);
        CFRelease(_compressionSession);
    }
}

@end