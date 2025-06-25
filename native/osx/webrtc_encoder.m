#import "webrtc_encoder.h"

// Compression callback for VideoToolbox
void compressionOutputCallback(void *outputCallbackRefCon,
                              void *sourceFrameRefCon,
                              OSStatus status,
                              VTEncodeInfoFlags infoFlags,
                              CMSampleBufferRef sampleBuffer) {
    
    if (status != noErr) {
        NSLog(@"❌ VideoToolbox encoding error: %d", (int)status);
        return;
    }
    
    if (!sampleBuffer) {
        NSLog(@"❌ No sample buffer from VideoToolbox");
        return;
    }
    
    WebRTCEncoder *encoder = (__bridge WebRTCEncoder *)outputCallbackRefCon;
    [encoder processSampleBuffer:sampleBuffer];
}

@implementation WebRTCEncoder

- (instancetype)initWithCodec:(CMVideoCodecType)codec 
                       width:(int)width 
                      height:(int)height 
                     bitrate:(int)bitrate 
                   framerate:(int)framerate {
    self = [super init];
    if (self) {
        self.codecType = codec;
        self.targetBitrate = bitrate;
        self.targetFramerate = framerate;
        self.encodedData = [NSMutableData data];
        
        [self setupCompressionSession:width height:height];
    }
    return self;
}

- (void)setupCompressionSession:(int)width height:(int)height {
    OSStatus status;
    
    // Create compression session
    status = VTCompressionSessionCreate(
        NULL,                           // allocator
        width,                          // width
        height,                         // height
        self.codecType,                 // codec type
        NULL,                           // encoder specification
        NULL,                           // source image buffer attributes
        NULL,                           // compressed data allocator
        compressionOutputCallback,      // output callback
        (__bridge void *)self,          // callback context
        &_compressionSession            // compression session out
    );
    
    if (status != noErr) {
        NSLog(@"❌ Failed to create VideoToolbox compression session: %d", (int)status);
        return;
    }
    
    NSLog(@"✅ Created VideoToolbox compression session: %dx%d %@", 
          width, height, [self codecName:self.codecType]);
    
    // Configure for real-time encoding
    [self configureRealTimeEncoding];
}

- (void)configureRealTimeEncoding {
    if (!self.compressionSession) return;
    
    // Enable real-time encoding
    VTSessionSetProperty(self.compressionSession,
                        kVTCompressionPropertyKey_RealTime,
                        kCFBooleanTrue);
    
    // Disable frame reordering for lower latency
    VTSessionSetProperty(self.compressionSession,
                        kVTCompressionPropertyKey_AllowFrameReordering,
                        kCFBooleanFalse);
    
    // Set target bitrate
    CFNumberRef bitrateNumber = CFNumberCreate(NULL, kCFNumberIntType, &_targetBitrate);
    VTSessionSetProperty(self.compressionSession,
                        kVTCompressionPropertyKey_AverageBitRate,
                        bitrateNumber);
    CFRelease(bitrateNumber);
    
    // Set max keyframe interval (for better seeking/error recovery)
    int keyFrameInterval = self.targetFramerate * 2; // Every 2 seconds
    CFNumberRef keyFrameNumber = CFNumberCreate(NULL, kCFNumberIntType, &keyFrameInterval);
    VTSessionSetProperty(self.compressionSession,
                        kVTCompressionPropertyKey_MaxKeyFrameInterval,
                        keyFrameNumber);
    CFRelease(keyFrameNumber);
    
    // Set expected framerate
    CFNumberRef fpsNumber = CFNumberCreate(NULL, kCFNumberIntType, &_targetFramerate);
    VTSessionSetProperty(self.compressionSession,
                        kVTCompressionPropertyKey_ExpectedFrameRate,
                        fpsNumber);
    CFRelease(fpsNumber);
    
    // Optimize for speed over quality
    VTSessionSetProperty(self.compressionSession,
                        kVTCompressionPropertyKey_Quality,
                        (__bridge CFTypeRef)@(0.7)); // 70% quality for speed
    
    // Enable hardware acceleration if available
    VTSessionSetProperty(self.compressionSession,
                        kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                        kCFBooleanTrue);
    
    // Low latency mode
    if (self.codecType == kCMVideoCodecType_H264) {
        // H.264 specific optimizations
        VTSessionSetProperty(self.compressionSession,
                            kVTCompressionPropertyKey_ProfileLevel,
                            kVTProfileLevel_H264_Main_AutoLevel);
        
        // Enable low latency
        VTSessionSetProperty(self.compressionSession,
                            kVTCompressionPropertyKey_H264EntropyMode,
                            kVTH264EntropyMode_CAVLC); // Faster than CABAC
    }
    
    NSLog(@"✅ Configured VideoToolbox for real-time encoding: %d kbps, %d fps",
          self.targetBitrate / 1000, self.targetFramerate);
}

- (NSData *)encodeFrame:(CVPixelBufferRef)pixelBuffer {
    if (!self.compressionSession || !pixelBuffer) {
        return nil;
    }
    
    // Clear previous encoded data
    [self.encodedData setLength:0];
    
    // Create frame properties
    CFMutableDictionaryRef frameProperties = CFDictionaryCreateMutable(
        NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    
    // Presentation timestamp
    CMTime presentationTimeStamp = CMTimeMake(CACurrentMediaTime() * 1000, 1000);
    
    // Encode the frame
    OSStatus status = VTCompressionSessionEncodeFrame(
        self.compressionSession,
        pixelBuffer,                    // source frame
        presentationTimeStamp,          // presentation timestamp
        kCMTimeInvalid,                // duration (invalid = auto)
        frameProperties,               // frame properties
        NULL,                          // source frame context
        NULL                           // output context
    );
    
    CFRelease(frameProperties);
    
    if (status != noErr) {
        NSLog(@"❌ VideoToolbox encode frame error: %d", (int)status);
        return nil;
    }
    
    // Force completion to get synchronous behavior
    VTCompressionSessionCompleteFrames(self.compressionSession, kCMTimeInvalid);
    
    // Return encoded data (filled by callback)
    return [self.encodedData copy];
}

- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    // Extract compressed data from sample buffer
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!blockBuffer) {
        NSLog(@"❌ No block buffer in sample");
        return;
    }
    
    size_t length = CMBlockBufferGetDataLength(blockBuffer);
    if (length == 0) {
        NSLog(@"❌ Empty block buffer");
        return;
    }
    
    // Get data pointer
    char *dataPointer = NULL;
    OSStatus status = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, NULL, &dataPointer);
    if (status != noErr || !dataPointer) {
        NSLog(@"❌ Failed to get data pointer: %d", (int)status);
        return;
    }
    
    // Append to encoded data
    [self.encodedData appendBytes:dataPointer length:length];
    
    // Log encoding info occasionally
    static int frameCount = 0;
    frameCount++;
    if (frameCount % 300 == 0) { // Every 10 seconds at 30fps
        NSLog(@"📹 VideoToolbox encoded %d frames, latest: %zu bytes", frameCount, length);
    }
}

- (void)updateBitrate:(int)newBitrate {
    if (!self.compressionSession) return;
    
    self.targetBitrate = newBitrate;
    
    CFNumberRef bitrateNumber = CFNumberCreate(NULL, kCFNumberIntType, &newBitrate);
    OSStatus status = VTSessionSetProperty(self.compressionSession,
                                          kVTCompressionPropertyKey_AverageBitRate,
                                          bitrateNumber);
    CFRelease(bitrateNumber);
    
    if (status == noErr) {
        NSLog(@"📊 Updated bitrate to %d kbps", newBitrate / 1000);
    } else {
        NSLog(@"❌ Failed to update bitrate: %d", (int)status);
    }
}

- (void)updateFramerate:(int)newFramerate {
    if (!self.compressionSession) return;
    
    self.targetFramerate = newFramerate;
    
    CFNumberRef fpsNumber = CFNumberCreate(NULL, kCFNumberIntType, &newFramerate);
    OSStatus status = VTSessionSetProperty(self.compressionSession,
                                          kVTCompressionPropertyKey_ExpectedFrameRate,
                                          fpsNumber);
    CFRelease(fpsNumber);
    
    if (status == noErr) {
        NSLog(@"📊 Updated framerate to %d fps", newFramerate);
    } else {
        NSLog(@"❌ Failed to update framerate: %d", (int)status);
    }
}

- (NSDictionary *)getEncodingStats {
    if (!self.compressionSession) {
        return @{};
    }
    
    NSMutableDictionary *stats = [NSMutableDictionary dictionary];
    
    // Get hardware acceleration status
    CFBooleanRef isUsingHardware = NULL;
    VTSessionCopyProperty(self.compressionSession,
                         kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                         NULL, &isUsingHardware);
    
    if (isUsingHardware) {
        stats[@"hardwareAccelerated"] = @(CFBooleanGetValue(isUsingHardware));
        CFRelease(isUsingHardware);
    }
    
    stats[@"codec"] = [self codecName:self.codecType];
    stats[@"targetBitrate"] = @(self.targetBitrate);
    stats[@"targetFramerate"] = @(self.targetFramerate);
    
    return [stats copy];
}

- (NSString *)codecName:(CMVideoCodecType)codec {
    switch (codec) {
        case kCMVideoCodecType_H264:
            return @"H.264";
        case kCMVideoCodecType_HEVC:
            return @"H.265/HEVC";
        case kCMVideoCodecType_VP9:
            return @"VP9";
        default:
            return [NSString stringWithFormat:@"Unknown (%u)", codec];
    }
}

- (void)cleanup {
    if (self.compressionSession) {
        VTCompressionSessionCompleteFrames(self.compressionSession, kCMTimeInvalid);
        VTCompressionSessionInvalidate(self.compressionSession);
        CFRelease(self.compressionSession);
        self.compressionSession = NULL;
        NSLog(@"✅ VideoToolbox compression session cleaned up");
    }
}

- (void)dealloc {
    [self cleanup];
}

@end