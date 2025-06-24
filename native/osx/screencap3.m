#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface ScreenCapture : NSObject <SCStreamOutput>
@property (nonatomic, strong) SCStream *stream;
@property (nonatomic, strong) dispatch_queue_t outputQueue;
@end

@implementation ScreenCapture

- (instancetype)init {
    self = [super init];
    if (self) {
        self.outputQueue = dispatch_queue_create("screencap.output", DISPATCH_QUEUE_SERIAL);
        [self setupCapture];
    }
    return self;
}

- (void)setupCapture {
    NSLog(@"🚀 Setting up ScreenCaptureKit...");
    
    // Get available content
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent * _Nullable content, NSError * _Nullable error) {
        if (error) {
            NSLog(@"❌ Error getting shareable content: %@", error.localizedDescription);
            return;
        }
        
        // Use the first display (main display)
        if (content.displays.count == 0) {
            NSLog(@"❌ No displays found!");
            return;
        }
        
        SCDisplay *display = content.displays.firstObject;
        NSLog(@"✅ Found display: %u (%d x %d)", display.displayID, (int)display.width, (int)display.height);
        
        // Create content filter for the display
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
        
        // Configure stream
        SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
        config.width = display.width;
        config.height = display.height;
        config.queueDepth = 3;
        config.pixelFormat = kCVPixelFormatType_32BGRA;
        config.showsCursor = YES;
        config.minimumFrameInterval = CMTimeMake(1, 30); // 30 FPS
        
        // Create stream
        self.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:nil];
        
        NSError *streamError;
        [self.stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self.outputQueue error:&streamError];
        
        if (streamError) {
            NSLog(@"❌ Error adding stream output: %@", streamError.localizedDescription);
            return;
        }
        
        // Start capture
        dispatch_semaphore_t startSemaphore = dispatch_semaphore_create(0);
        
        [self.stream startCaptureWithCompletionHandler:^(NSError * _Nullable startError) {
            if (startError) {
                NSLog(@"❌ Error starting capture: %@", startError.localizedDescription);
            } else {
                NSLog(@"✅ Screen capture started successfully!");
            }
            dispatch_semaphore_signal(startSemaphore);
        }];
        
        dispatch_semaphore_wait(startSemaphore, DISPATCH_TIME_FOREVER);
    }];
}

#pragma mark - SCStreamOutput

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen) return;
    
    // Get image buffer
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) return;
    
    // Lock the buffer
    CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
    
    // Create CGImage from buffer
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
    if (!ciImage) {
        NSLog(@"❌ Failed to create CIImage");
        CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
        return;
    }
    
    CIContext *context = [CIContext context];
    if (!context) {
        NSLog(@"❌ Failed to create CIContext");
        CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
        return;
    }
    
    CGImageRef cgImage = [context createCGImage:ciImage fromRect:ciImage.extent];
    
    if (cgImage) {
        // Convert to JPEG and write to stdout
        NSMutableData *jpegData = [NSMutableData data];
        CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpegData,
                                                                             (__bridge CFStringRef)UTTypeJPEG.identifier,
                                                                             1, NULL);
        
        if (destination) {
            // Set JPEG quality
            NSDictionary *options = @{
                (__bridge NSString*)kCGImageDestinationLossyCompressionQuality: @(0.8),
                (__bridge NSString*)kCGImageDestinationImageMaxPixelSize: @(1920) // Max dimension
            };
            
            CGImageDestinationAddImage(destination, cgImage, (__bridge CFDictionaryRef)options);
            CGImageDestinationFinalize(destination);
            CFRelease(destination);
            
            // Write JPEG data to stdout
            fwrite([jpegData bytes], 1, [jpegData length], stdout);
            fflush(stdout);
        }
        
        CGImageRelease(cgImage);
    }
    
    // Unlock the buffer
    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSLog(@"🔥 macOS ScreenCaptureKit Tool Starting...");
        
        ScreenCapture *capture = [[ScreenCapture alloc] init];
        
        // Keep running
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}