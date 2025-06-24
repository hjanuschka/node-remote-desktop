#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CoreGraphics/CoreGraphics.h>

@interface ScreenCapture : NSObject <SCStreamOutput>
@property (nonatomic, strong) SCStream *stream;
@property (nonatomic, strong) dispatch_queue_t outputQueue;
@property (nonatomic, assign) CMTime firstSampleTime;
@end

@implementation ScreenCapture

- (instancetype)init {
    self = [super init];
    if (self) {
        self.outputQueue = dispatch_queue_create("screencap.output", DISPATCH_QUEUE_SERIAL);
        self.firstSampleTime = kCMTimeZero;
        [self setupCapture];
    }
    return self;
}

- (void)setupCapture {
    NSLog(@"🚀 Setting up ScreenCaptureKit...");
    
    // Check permissions first
    if (!CGPreflightScreenCaptureAccess()) {
        NSLog(@"❌ No screen capture permission! Please enable in System Preferences > Privacy & Security > Screen Recording");
        return;
    }
    
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
        
        // Configure stream - using settings from the example
        SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
        config.width = display.width;
        config.height = display.height;
        config.queueDepth = 6; // Critical: minimum 4 to avoid stuttering
        config.pixelFormat = kCVPixelFormatType_32BGRA; // Best for JPEG conversion
        config.colorSpaceName = kCGColorSpaceSRGB;
        config.showsCursor = YES;
        config.minimumFrameInterval = CMTimeMake(1, 30); // 30 FPS
        
        // Create stream
        self.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:nil];
        
        NSError *streamError;
        BOOL success = [self.stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self.outputQueue error:&streamError];
        
        if (!success || streamError) {
            NSLog(@"❌ Error adding stream output: %@", streamError.localizedDescription);
            return;
        }
        
        // Start capture
        [self.stream startCaptureWithCompletionHandler:^(NSError * _Nullable startError) {
            if (startError) {
                NSLog(@"❌ Error starting capture: %@", startError.localizedDescription);
            } else {
                NSLog(@"✅ Screen capture started successfully!");
            }
        }];
    }];
}

#pragma mark - SCStreamOutput

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen) return;
    
    // Check frame status like the example does
    CFArrayRef attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, FALSE);
    if (!attachmentsArray) return;
    
    CFDictionaryRef attachments = CFArrayGetValueAtIndex(attachmentsArray, 0);
    if (!attachments) return;
    
    // Check if frame is complete
    CFNumberRef statusNum = CFDictionaryGetValue(attachments, CFSTR("SCStreamFrameInfo.status"));
    if (statusNum) {
        int status;
        CFNumberGetValue(statusNum, kCFNumberIntType, &status);
        if (status != 0) return; // 0 = SCFrameStatusComplete
    }
    
    // Get image buffer
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) return;
    
    // Lock the buffer
    CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
    
    // Create CGImage from buffer - simplified approach
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
    void *baseAddress = CVPixelBufferGetBaseAddress(imageBuffer);
    
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef bitmapContext = CGBitmapContextCreate(baseAddress, width, height, 8, bytesPerRow, 
                                                       colorSpace, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    
    if (bitmapContext) {
        CGImageRef cgImage = CGBitmapContextCreateImage(bitmapContext);
        
        if (cgImage) {
            // Convert to JPEG and write to stdout
            NSMutableData *jpegData = [NSMutableData data];
            CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpegData,
                                                                                 (__bridge CFStringRef)UTTypeJPEG.identifier,
                                                                                 1, NULL);
            
            if (destination) {
                // Set JPEG quality
                NSDictionary *options = @{
                    (__bridge NSString*)kCGImageDestinationLossyCompressionQuality: @(0.75),
                    (__bridge NSString*)kCGImageDestinationImageMaxPixelSize: @(1920) // Max dimension
                };
                
                CGImageDestinationAddImage(destination, cgImage, (__bridge CFDictionaryRef)options);
                CGImageDestinationFinalize(destination);
                CFRelease(destination);
                
                // Write JPEG data to stdout
                fwrite([jpegData bytes], 1, [jpegData length], stdout);
                fflush(stdout);
                
                // Log progress occasionally
                static int frameCount = 0;
                frameCount++;
                if (frameCount % 60 == 0) { // Every 2 seconds at 30fps
                    NSLog(@"📸 Captured %d frames", frameCount);
                }
            }
            
            CGImageRelease(cgImage);
        }
        
        CGContextRelease(bitmapContext);
    }
    
    CGColorSpaceRelease(colorSpace);
    
    // Unlock the buffer
    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSLog(@"🔥 macOS ScreenCaptureKit Tool v5 Starting...");
        
        ScreenCapture *capture = [[ScreenCapture alloc] init];
        
        // Keep running
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}