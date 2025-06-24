#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface ScreenCapture : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;
@property (nonatomic, strong) dispatch_queue_t outputQueue;
@end

@implementation ScreenCapture

- (instancetype)init {
    self = [super init];
    if (self) {
        [self setupCapture];
    }
    return self;
}

- (void)setupCapture {
    // Create capture session
    self.captureSession = [[AVCaptureSession alloc] init];
    
    // Use modern device discovery
    AVCaptureDeviceDiscoverySession *discoverySession = [AVCaptureDeviceDiscoverySession 
        discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeExternalUnknown]
        mediaType:AVMediaTypeVideo
        position:AVCaptureDevicePositionUnspecified];
    
    AVCaptureDevice *screenDevice = nil;
    
    // List all devices for debugging
    NSLog(@"📱 Available devices:");
    for (AVCaptureDevice *device in discoverySession.devices) {
        NSLog(@"  - %@ (ID: %@)", device.localizedName, device.uniqueID);
        if ([device.localizedName containsString:@"Capture screen"] || 
            [device.localizedName containsString:@"Screen"]) {
            screenDevice = device;
        }
    }
    
    // If not found, try direct screen input
    if (!screenDevice) {
        NSLog(@"⚠️  No screen device found via discovery, trying direct screen input...");
        screenDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    }
    
    if (!screenDevice) {
        NSLog(@"❌ No screen capture device found!");
        return;
    }
    
    NSLog(@"✅ Using device: %@", screenDevice.localizedName);
    
    // Create input
    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:screenDevice error:&error];
    if (error) {
        NSLog(@"❌ Error creating input: %@", error.localizedDescription);
        return;
    }
    
    // Add input to session
    if ([self.captureSession canAddInput:input]) {
        [self.captureSession addInput:input];
    }
    
    // Create video output
    self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    
    // Set pixel format to JPEG-friendly
    self.videoOutput.videoSettings = @{
        (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    
    // Create output queue
    self.outputQueue = dispatch_queue_create("screencap.output", DISPATCH_QUEUE_SERIAL);
    [self.videoOutput setSampleBufferDelegate:self queue:self.outputQueue];
    
    // Add output to session
    if ([self.captureSession canAddOutput:self.videoOutput]) {
        [self.captureSession addOutput:self.videoOutput];
    }
    
    NSLog(@"✅ Screen capture setup complete!");
}

- (void)startCapture {
    NSLog(@"🚀 Starting screen capture...");
    [self.captureSession startRunning];
}

- (void)stopCapture {
    NSLog(@"⏹️ Stopping screen capture...");
    [self.captureSession stopRunning];
}

// Delegate method - called for each frame
- (void)captureOutput:(AVCaptureOutput *)output 
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer 
       fromConnection:(AVCaptureConnection *)connection {
    
    // Get image buffer
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    
    // Lock the buffer
    CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
    
    // Create CGImage from buffer
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:imageBuffer];
    CIContext *context = [CIContext context];
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
                (__bridge NSString*)kCGImageDestinationLossyCompressionQuality: @(0.7)
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
        NSLog(@"🔥 macOS Screen Capture Tool Starting...");
        
        ScreenCapture *capture = [[ScreenCapture alloc] init];
        [capture startCapture];
        
        // Keep running
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}