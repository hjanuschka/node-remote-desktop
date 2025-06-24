#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>

typedef enum {
    CaptureTypeFullDesktop = 0,
    CaptureTypeApplication = 1,
    CaptureTypeWindow = 2
} CaptureType;

@interface ScreenCapture : NSObject <SCStreamOutput>
@property (nonatomic, strong) SCStream *stream;
@property (nonatomic, strong) dispatch_queue_t outputQueue;
@property (nonatomic, strong) dispatch_queue_t inputQueue;
@property (nonatomic, assign) CMTime firstSampleTime;
@property (nonatomic, assign) CaptureType captureType;
@property (nonatomic, assign) int targetIndex;
@end

@implementation ScreenCapture

- (instancetype)init {
    return [self initWithCaptureType:CaptureTypeFullDesktop targetIndex:0];
}

- (instancetype)initWithCaptureType:(CaptureType)captureType targetIndex:(int)targetIndex {
    self = [super init];
    if (self) {
        self.outputQueue = dispatch_queue_create("screencap.output", DISPATCH_QUEUE_SERIAL);
        self.inputQueue = dispatch_queue_create("screencap.input", DISPATCH_QUEUE_SERIAL);
        self.firstSampleTime = kCMTimeZero;
        self.captureType = captureType;
        self.targetIndex = targetIndex;
        [self setupCapture];
        [self startInputListener];
    }
    return self;
}

- (void)setupCapture {
    NSLog(@"🚀 Setting up ScreenCaptureKit...");
    
    // Check and request screen capture permissions
    if (!CGPreflightScreenCaptureAccess()) {
        NSLog(@"❌ No screen capture permission!");
        NSLog(@"🔒 Requesting screen capture access...");
        
        // This will trigger the permission dialog
        CGRequestScreenCaptureAccess();
        
        // Wait a bit and check again
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (!CGPreflightScreenCaptureAccess()) {
                NSLog(@"❌ Still no screen capture permission! Please enable in System Preferences > Privacy & Security > Screen Recording");
                exit(1);
            } else {
                NSLog(@"✅ Screen capture permission granted!");
                [self continueSetup];
            }
        });
        return;
    }
    
    [self continueSetup];
}

- (void)continueSetup {
    // Get available content
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent * _Nullable content, NSError * _Nullable error) {
        if (error) {
            NSLog(@"❌ Error getting shareable content: %@", error.localizedDescription);
            return;
        }
        
        SCContentFilter *filter = nil;
        CGSize captureSize = CGSizeMake(1920, 1080); // Default size
        
        if (self.captureType == CaptureTypeFullDesktop) {
            // Full desktop capture (existing logic)
            if (content.displays.count == 0) {
                NSLog(@"❌ No displays found!");
                return;
            }
            
            SCDisplay *display = content.displays.firstObject;
            NSLog(@"✅ Found display: %u (%d x %d)", display.displayID, (int)display.width, (int)display.height);
            captureSize = CGSizeMake(display.width, display.height);
            filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
            
        } else if (self.captureType == CaptureTypeApplication) {
            // Application capture - get applications with visible names
            NSArray *allApplications = content.applications;
            NSMutableArray *visibleApplications = [NSMutableArray array];
            
            for (SCRunningApplication *app in allApplications) {
                if (app.applicationName && ![app.applicationName isEqualToString:@""]) {
                    [visibleApplications addObject:app];
                }
            }
            
            if (self.targetIndex <= 0 || self.targetIndex > visibleApplications.count) {
                NSLog(@"❌ Invalid application index: %d (available: 1-%lu)", self.targetIndex, (unsigned long)visibleApplications.count);
                return;
            }
            
            SCRunningApplication *targetApp = visibleApplications[self.targetIndex - 1];
            NSLog(@"✅ Capturing application: %@ (PID: %d)", targetApp.applicationName, targetApp.processID);
            
            // Get all visible windows for this application
            NSMutableArray *appWindows = [NSMutableArray array];
            for (SCWindow *window in content.windows) {
                if (window.owningApplication.processID == targetApp.processID && 
                    window.title && ![window.title isEqualToString:@""] &&
                    window.frame.size.width > 100 && window.frame.size.height > 100) {
                    [appWindows addObject:window];
                }
            }
            
            if (appWindows.count == 0) {
                NSLog(@"❌ No visible windows found for application: %@", targetApp.applicationName);
                return;
            }
            
            // Sort windows by size (largest first)
            [appWindows sortUsingComparator:^NSComparisonResult(SCWindow *a, SCWindow *b) {
                CGFloat areaA = a.frame.size.width * a.frame.size.height;
                CGFloat areaB = b.frame.size.width * b.frame.size.height;
                return areaB > areaA ? NSOrderedAscending : NSOrderedDescending;
            }];
            
            SCWindow *mainWindow = appWindows.firstObject;
            NSLog(@"📏 Main window: %@ (%.0fx%.0f)", mainWindow.title, mainWindow.frame.size.width, mainWindow.frame.size.height);
            
            captureSize = mainWindow.frame.size;
            
            // Use display-based filter with included applications to avoid CGS issues
            SCDisplay *display = content.displays.firstObject;
            NSMutableArray *excludedWindows = [NSMutableArray array];
            
            // Exclude windows from other applications
            for (SCWindow *window in content.windows) {
                if (window.owningApplication.processID != targetApp.processID) {
                    [excludedWindows addObject:window];
                }
            }
            
            filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:excludedWindows];
            
        } else if (self.captureType == CaptureTypeWindow) {
            // Individual window capture
            NSArray *windows = content.windows;
            NSArray *visibleWindows = [windows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SCWindow *window, NSDictionary *bindings) {
                return window.title && ![window.title isEqualToString:@""];
            }]];
            
            int windowIndex = self.targetIndex - (int)content.applications.count - 1;
            if (windowIndex < 0 || windowIndex >= visibleWindows.count) {
                NSLog(@"❌ Invalid window index: %d (available visible windows: %lu)", windowIndex, (unsigned long)visibleWindows.count);
                return;
            }
            
            SCWindow *targetWindow = visibleWindows[windowIndex];
            NSLog(@"✅ Capturing window: %@ - %@ (%.0fx%.0f)", 
                  targetWindow.owningApplication.applicationName ?: @"Unknown", 
                  targetWindow.title, 
                  targetWindow.frame.size.width, 
                  targetWindow.frame.size.height);
            
            captureSize = targetWindow.frame.size;
            filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:targetWindow];
        }
        
        if (!filter) {
            NSLog(@"❌ Failed to create content filter");
            return;
        }
        
        // Configure stream - 30 FPS for all capture types
        SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
        config.width = (int)captureSize.width;
        config.height = (int)captureSize.height;
        config.queueDepth = 6;
        config.pixelFormat = kCVPixelFormatType_32BGRA;
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
                NSString *captureTypeStr = self.captureType == CaptureTypeFullDesktop ? @"full desktop" : 
                                          self.captureType == CaptureTypeApplication ? @"application" : @"window";
                NSLog(@"✅ %@ capture started successfully at 30 FPS!", captureTypeStr);
                NSLog(@"📝 Send commands via stdin: 'click x y' or 'key character'");
            }
        }];
    }];
}

- (void)startInputListener {
    NSLog(@"👂 Starting input listener on stdin...");
    dispatch_async(self.inputQueue, ^{
        char buffer[256];
        while (fgets(buffer, sizeof(buffer), stdin)) {
            NSString *command = [NSString stringWithCString:buffer encoding:NSUTF8StringEncoding];
            command = [command stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
            NSLog(@"📥 Received command: '%@'", command);
            [self processCommand:command];
        }
    });
}

- (void)processCommand:(NSString *)command {
    NSArray *parts = [command componentsSeparatedByString:@" "];
    if (parts.count == 0) {
        NSLog(@"❓ Empty command received");
        return;
    }
    
    NSString *action = parts[0];
    NSLog(@"🔍 Processing action: '%@' with %lu parts", action, (unsigned long)parts.count);
    
    if ([action isEqualToString:@"click"] && parts.count >= 3) {
        int x = [parts[1] intValue];
        int y = [parts[2] intValue];
        NSLog(@"🎯 Parsed click coordinates: x=%d, y=%d", x, y);
        [self performClick:x y:y];
    } else if ([action isEqualToString:@"key"] && parts.count >= 2) {
        NSString *key = parts[1];
        NSLog(@"🎯 Parsed key: '%@'", key);
        [self performKeyPress:key];
    } else {
        NSLog(@"❓ Unknown command: '%@' (parts: %@)", command, parts);
    }
}

- (void)performClick:(int)x y:(int)y {
    NSLog(@"🖱️ Clicking at %d,%d", x, y);
    
    // Check accessibility permissions
    if (!AXIsProcessTrusted()) {
        NSLog(@"❌ No accessibility permission for mouse events!");
        NSLog(@"🔒 Please enable accessibility for this app in System Preferences > Privacy & Security > Accessibility");
        return;
    }
    
    // Create a mouse click event
    CGEventRef mouseDown = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, CGPointMake(x, y), kCGMouseButtonLeft);
    CGEventRef mouseUp = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, CGPointMake(x, y), kCGMouseButtonLeft);
    
    if (mouseDown && mouseUp) {
        // Post the events
        CGEventPost(kCGHIDEventTap, mouseDown);
        CGEventPost(kCGHIDEventTap, mouseUp);
        
        CFRelease(mouseDown);
        CFRelease(mouseUp);
        NSLog(@"✅ Click executed");
    } else {
        NSLog(@"❌ Failed to create mouse events");
    }
}

- (void)performKeyPress:(NSString *)key {
    NSLog(@"⌨️ Key press: %@", key);
    
    if (key.length == 0) return;
    
    // Check accessibility permissions
    if (!AXIsProcessTrusted()) {
        NSLog(@"❌ No accessibility permission for keyboard events!");
        NSLog(@"🔒 Please enable accessibility for this app in System Preferences > Privacy & Security > Accessibility");
        return;
    }
    
    CGKeyCode keyCode = 0;
    unichar character = [key characterAtIndex:0];
    
    // Complete key mapping for all letters and common keys
    switch (character) {
        case 'a': case 'A': keyCode = 0; break;
        case 's': case 'S': keyCode = 1; break;
        case 'd': case 'D': keyCode = 2; break;
        case 'f': case 'F': keyCode = 3; break;
        case 'h': case 'H': keyCode = 4; break;
        case 'g': case 'G': keyCode = 5; break;
        case 'z': case 'Z': keyCode = 6; break;
        case 'x': case 'X': keyCode = 7; break;
        case 'c': case 'C': keyCode = 8; break;
        case 'v': case 'V': keyCode = 9; break;
        case 'b': case 'B': keyCode = 11; break;
        case 'q': case 'Q': keyCode = 12; break;
        case 'w': case 'W': keyCode = 13; break;
        case 'e': case 'E': keyCode = 14; break;
        case 'r': case 'R': keyCode = 15; break;
        case 'y': case 'Y': keyCode = 16; break;
        case 't': case 'T': keyCode = 17; break;
        case '1': keyCode = 18; break;
        case '2': keyCode = 19; break;
        case '3': keyCode = 20; break;
        case '4': keyCode = 21; break;
        case '6': keyCode = 22; break;
        case '5': keyCode = 23; break;
        case '=': keyCode = 24; break;
        case '9': keyCode = 25; break;
        case '7': keyCode = 26; break;
        case '-': keyCode = 27; break;
        case '8': keyCode = 28; break;
        case '0': keyCode = 29; break;
        case ']': keyCode = 30; break;
        case 'o': case 'O': keyCode = 31; break;  // Added 'o'
        case 'u': case 'U': keyCode = 32; break;
        case '[': keyCode = 33; break;
        case 'i': case 'I': keyCode = 34; break;
        case 'p': case 'P': keyCode = 35; break;
        case 'l': case 'L': keyCode = 37; break;  // Added 'l'
        case 'j': case 'J': keyCode = 38; break;
        case '\'': keyCode = 39; break;
        case 'k': case 'K': keyCode = 40; break;
        case ';': keyCode = 41; break;
        case '\\': keyCode = 42; break;
        case ',': keyCode = 43; break;
        case '/': keyCode = 44; break;
        case 'n': case 'N': keyCode = 45; break;
        case 'm': case 'M': keyCode = 46; break;
        case '.': keyCode = 47; break;
        case ' ': keyCode = 49; break; // Space
        default:
            NSLog(@"❓ Unknown key: %@", key);
            return;
    }
    
    // Create key events
    CGEventRef keyDown = CGEventCreateKeyboardEvent(NULL, keyCode, true);
    CGEventRef keyUp = CGEventCreateKeyboardEvent(NULL, keyCode, false);
    
    if (keyDown && keyUp) {
        CGEventPost(kCGHIDEventTap, keyDown);
        CGEventPost(kCGHIDEventTap, keyUp);
        
        CFRelease(keyDown);
        CFRelease(keyUp);
    }
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
                    NSLog(@"📸 Captured %d frames at 30 FPS", frameCount);
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

void listApplicationsAndWindows() {
    NSLog(@"🔍 Listing all available applications and windows...");
    
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent * _Nullable content, NSError * _Nullable error) {
        if (error) {
            NSLog(@"❌ Error getting shareable content: %@", error.localizedDescription);
            return;
        }
        
        NSLog(@"📱 Available Applications:");
        NSLog(@"0: 📺 FULL DESKTOP (all displays)");
        
        // Filter visible applications
        NSMutableArray *visibleApplications = [NSMutableArray array];
        for (SCRunningApplication *app in content.applications) {
            if (app.applicationName && ![app.applicationName isEqualToString:@""]) {
                [visibleApplications addObject:app];
            }
        }
        
        int index = 1;
        for (SCRunningApplication *app in visibleApplications) {
            NSLog(@"%d: 🚀 %@ (PID: %d)", index, app.applicationName, app.processID);
            index++;
        }
        
        NSLog(@"📂 Available Windows:");
        for (SCWindow *window in content.windows) {
            if (window.title && ![window.title isEqualToString:@""]) {
                SCRunningApplication *ownerApp = window.owningApplication;
                NSString *appName = ownerApp.applicationName ?: @"Unknown";
                NSLog(@"%d: 🪟 %@ - %@ (%.0fx%.0f)", index, appName, window.title, window.frame.size.width, window.frame.size.height);
                index++;
            }
        }
        
        NSLog(@"📝 Usage: ./screencap6 [option]");
        NSLog(@"   ./screencap6           - Full desktop capture (default)");
        NSLog(@"   ./screencap6 list      - Show this list");
        NSLog(@"   ./screencap6 app N     - Capture application N");
        NSLog(@"   ./screencap6 window N  - Capture window N");
        
        exit(0);
    }];
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSLog(@"🔥 macOS ScreenCaptureKit Tool v6 Starting with Input Support...");
        
        // Parse command line arguments
        if (argc > 1) {
            NSString *command = [NSString stringWithUTF8String:argv[1]];
            
            if ([command isEqualToString:@"list"]) {
                listApplicationsAndWindows();
                [[NSRunLoop currentRunLoop] run];
                return 0;
            }
        }
        
        // Check initial permissions
        BOOL hasScreenPermission = CGPreflightScreenCaptureAccess();
        BOOL hasAccessibilityPermission = AXIsProcessTrusted();
        
        NSLog(@"📋 Permission Status:");
        NSLog(@"   Screen Recording: %@", hasScreenPermission ? @"✅ GRANTED" : @"❌ DENIED");
        NSLog(@"   Accessibility: %@", hasAccessibilityPermission ? @"✅ GRANTED" : @"❌ DENIED");
        
        if (!hasScreenPermission) {
            NSLog(@"🔒 Screen recording permission required for video capture");
        }
        if (!hasAccessibilityPermission) {
            NSLog(@"🔒 Accessibility permission required for mouse/keyboard input");
        }
        
        ScreenCapture *capture;
        
        // Create capture with specified parameters
        if (argc > 1) {
            NSString *command = [NSString stringWithUTF8String:argv[1]];
            
            if ([command isEqualToString:@"app"] && argc > 2) {
                int appIndex = atoi(argv[2]);
                capture = [[ScreenCapture alloc] initWithCaptureType:CaptureTypeApplication targetIndex:appIndex];
            } else if ([command isEqualToString:@"window"] && argc > 2) {
                int windowIndex = atoi(argv[2]);
                capture = [[ScreenCapture alloc] initWithCaptureType:CaptureTypeWindow targetIndex:windowIndex];
            } else {
                capture = [[ScreenCapture alloc] init]; // Default full desktop
            }
        } else {
            capture = [[ScreenCapture alloc] init]; // Default full desktop
        }
        
        // Keep running
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}