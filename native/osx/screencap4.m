#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

void captureAndSendFrame() {
    // Get main display
    CGDirectDisplayID displayID = CGMainDisplayID();
    
    // Create screenshot using modern API
    CGImageRef screenshot = CGDisplayCreateImage(displayID);
    
    if (screenshot) {
        // Convert to JPEG
        NSMutableData *jpegData = [NSMutableData data];
        CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpegData,
                                                                             (__bridge CFStringRef)UTTypeJPEG.identifier,
                                                                             1, NULL);
        
        if (destination) {
            // Set JPEG quality
            NSDictionary *options = @{
                (__bridge NSString*)kCGImageDestinationLossyCompressionQuality: @(0.7)
            };
            
            CGImageDestinationAddImage(destination, screenshot, (__bridge CFDictionaryRef)options);
            CGImageDestinationFinalize(destination);
            CFRelease(destination);
            
            // Write JPEG data to stdout
            fwrite([jpegData bytes], 1, [jpegData length], stdout);
            fflush(stdout);
        }
        
        CGImageRelease(screenshot);
    } else {
        NSLog(@"❌ Failed to capture screen");
    }
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSLog(@"🔥 macOS Simple Screen Capture v4 Starting...");
        
        // Default to 15 FPS for better performance
        int fps = 15;
        if (argc > 1) {
            fps = atoi(argv[1]);
        }
        
        NSLog(@"📸 Capturing at %d FPS", fps);
        
        // Calculate frame interval in microseconds
        useconds_t frameInterval = 1000000 / fps;
        
        // Main capture loop
        while (true) {
            captureAndSendFrame();
            usleep(frameInterval);
        }
    }
    return 0;
}