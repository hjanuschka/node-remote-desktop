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
@property (nonatomic, strong) NSMutableData *currentFrame;
@property (nonatomic, assign) BOOL isCapturing;
@property (nonatomic, strong) NSString *cachedWindowsList;
@property (nonatomic, strong) NSTimer *windowsUpdateTimer;
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
        self.currentFrame = [NSMutableData data];
        self.isCapturing = NO;
        self.cachedWindowsList = @"[]"; // Default empty list
        [self startWindowsCaching];
        [self setupCapture];
    }
    return self;
}

- (void)startWindowsCaching {
    // Update windows list every 2 seconds on background thread
    self.windowsUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            [self updateWindowsCache];
        });
    }];
    
    // Get initial list immediately
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        [self updateWindowsCache];
    });
}

- (void)updateWindowsCache {
    NSString *newList = [self generateWindowsList];
    if (newList) {
        self.cachedWindowsList = newList;
    }
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
            // Individual window capture by CGWindowID
            UInt32 targetCGWindowID = (UInt32)self.targetIndex; // targetIndex stores the CGWindowID
            NSArray *windows = content.windows;
            
            SCWindow *targetWindow = nil;
            for (SCWindow *window in windows) {
                if (window.windowID == targetCGWindowID) {
                    targetWindow = window;
                    break;
                }
            }
            
            if (!targetWindow) {
                NSLog(@"❌ Window with CGWindowID %u not found in available windows", targetCGWindowID);
                NSLog(@"💡 Available windows count: %lu", (unsigned long)windows.count);
                // Fallback to full desktop if window not found
                NSLog(@"🔄 Falling back to full desktop capture");
                SCDisplay *display = content.displays.firstObject;
                if (display) {
                    captureSize = CGSizeMake(display.width, display.height);
                    filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
                }
            } else {
                NSLog(@"✅ Found and capturing window: %@ - %@ (%.0fx%.0f) [CGWindowID: %u]", 
                      targetWindow.owningApplication.applicationName ?: @"Unknown", 
                      targetWindow.title ?: @"Untitled", 
                      targetWindow.frame.size.width, 
                      targetWindow.frame.size.height,
                      targetCGWindowID);
                
                captureSize = targetWindow.frame.size;
                filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:targetWindow];
            }
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
    
    // Only process frames from the current active stream
    if (stream != self.stream) {
        static int ignoreCount = 0;
        if (++ignoreCount % 300 == 0) {
            NSLog(@"🚫 Ignoring frame from old stream %p (current: %p)", stream, self.stream);
        }
        return;
    }
    
    // Log which stream this is coming from
    static int streamLogCount = 0;
    if (++streamLogCount % 900 == 0) { // Every 30 seconds
        NSLog(@"🎬 Frame from current stream %p | Mode: %d | Target: %d", 
              stream, (int)self.captureType, self.targetIndex);
    }
    
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
        
        // Add a colored border for window captures to verify it's working
        if (self.captureType == CaptureTypeWindow && cgImage) {
            CGContextRef borderContext = CGBitmapContextCreate(NULL, width, height, 8, 0,
                                                              colorSpace, kCGImageAlphaPremultipliedFirst);
            if (borderContext) {
                // Draw the original image
                CGContextDrawImage(borderContext, CGRectMake(0, 0, width, height), cgImage);
                
                // Draw a green border for window captures
                CGContextSetRGBStrokeColor(borderContext, 0.0, 1.0, 0.0, 1.0); // Green
                CGContextSetLineWidth(borderContext, 10.0);
                CGContextStrokeRect(borderContext, CGRectMake(5, 5, width-10, height-10));
                
                // Draw window ID text
                NSString *windowText = [NSString stringWithFormat:@"Window: %d", self.targetIndex];
                NSAttributedString *attrStr = [[NSAttributedString alloc] initWithString:windowText
                    attributes:@{NSFontAttributeName: [NSFont boldSystemFontOfSize:24],
                               NSForegroundColorAttributeName: [NSColor greenColor]}];
                
                CGContextSetRGBFillColor(borderContext, 0.0, 0.0, 0.0, 0.7); // Black background
                CGContextFillRect(borderContext, CGRectMake(10, 10, 200, 40));
                
                // Replace the original image with the bordered one
                CGImageRelease(cgImage);
                cgImage = CGBitmapContextCreateImage(borderContext);
                CGContextRelease(borderContext);
            }
        }
        
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
                
                // Store JPEG data for HTTP server
                @synchronized(self.currentFrame) {
                    [self.currentFrame setData:jpegData];
                }
                
                // Log progress occasionally (disabled to reduce spam)
                static int frameCount = 0;
                frameCount++;
                if (frameCount % 300 == 0) { // Every 10 seconds at 30fps
                    NSString *captureInfo = @"Unknown";
                    if (self.captureType == CaptureTypeFullDesktop) {
                        captureInfo = @"Full Desktop";
                    } else if (self.captureType == CaptureTypeWindow) {
                        captureInfo = [NSString stringWithFormat:@"Window ID: %d", self.targetIndex];
                    }
                    NSLog(@"📸 Captured %d frames | Mode: %@ | Size: %zux%zu", frameCount, captureInfo, width, height);
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

- (NSData *)getCurrentFrame {
    @synchronized(self.currentFrame) {
        return [self.currentFrame copy];
    }
}

- (void)startCaptureWithType:(CaptureType)captureType targetIndex:(int)targetIndex {
    self.captureType = captureType;
    self.targetIndex = targetIndex;
    [self setupCapture];
}

- (void)startCaptureWithWindowID:(UInt32)windowID {
    NSLog(@"🎯 startCaptureWithWindowID called with ID: %u", windowID);
    
    // Special method for capturing specific windows by CGWindowID
    self.captureType = CaptureTypeWindow;
    self.targetIndex = (int)windowID; // Store windowID in targetIndex
    
    NSLog(@"🎯 About to call setupWindowCapture...");
    [self setupWindowCapture:windowID];
    NSLog(@"🎯 setupWindowCapture returned");
}

- (void)setupWindowCapture:(UInt32)windowID {
    NSLog(@"🚀 Setting up window capture for CGWindowID: %u", windowID);
    
    // Check permissions
    if (!CGPreflightScreenCaptureAccess()) {
        NSLog(@"❌ No screen capture permission!");
        return;
    }
    
    // Stop existing stream immediately to avoid conflicts
    if (self.stream) {
        NSLog(@"⚠️ Stopping existing stream before window capture...");
        SCStream *oldStream = self.stream;
        self.stream = nil;
        self.isCapturing = NO;
        
        [oldStream stopCaptureWithCompletionHandler:^(NSError * _Nullable error) {
            if (error) {
                NSLog(@"❌ Error stopping old stream: %@", error.localizedDescription);
            } else {
                NSLog(@"✅ Old stream stopped successfully");
            }
        }];
        
        // Wait a bit for cleanup
        [NSThread sleepForTimeInterval:0.3];
    }
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent * _Nullable content, NSError * _Nullable error) {
            if (error) {
                NSLog(@"❌ Error getting shareable content: %@", error.localizedDescription);
                return;
            }
            
            // Find the window by CGWindowID
            SCWindow *targetWindow = nil;
            for (SCWindow *window in content.windows) {
                if (window.windowID == windowID) {
                    targetWindow = window;
                    break;
                }
            }
            
            SCContentFilter *filter;
            SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
            
            if (!targetWindow) {
                NSLog(@"❌ Window with ID %u not found! Falling back to desktop capture.", windowID);
                // Fallback to desktop if window not found
                if (content.displays.count == 0) {
                    NSLog(@"❌ No displays found!");
                    return;
                }
                SCDisplay *display = content.displays.firstObject;
                filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
                
                // Configure stream for full desktop
                config.width = (int)display.width;
                config.height = (int)display.height;
            } else {
                NSLog(@"✅ Found window: %@ (ID: %u)", targetWindow.title, windowID);
                
                // Create filter for specific window
                filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:targetWindow];
                
                // Configure stream for window
                CGRect frame = targetWindow.frame;
                config.width = (int)CGRectGetWidth(frame);
                config.height = (int)CGRectGetHeight(frame);
            }
            
            // Common configuration
            config.queueDepth = 6;
            config.pixelFormat = kCVPixelFormatType_32BGRA;
            config.colorSpaceName = kCGColorSpaceSRGB;
            config.showsCursor = YES;
            config.minimumFrameInterval = CMTimeMake(1, 30); // 30 FPS
            
            // Create new stream on main queue
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    self.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:nil];
                    
                    if (!self.stream) {
                        NSLog(@"❌ Failed to create SCStream!");
                        return;
                    }
                    
                    NSError *streamError;
                    BOOL success = [self.stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self.outputQueue error:&streamError];
                    
                    if (!success || streamError) {
                        NSLog(@"❌ Error adding stream output: %@", streamError.localizedDescription);
                        self.stream = nil;
                        return;
                    }
                    
                    // Start capture
                    [self.stream startCaptureWithCompletionHandler:^(NSError * _Nullable startError) {
                        if (startError) {
                            NSLog(@"❌ Error starting capture: %@", startError.localizedDescription);
                            self.stream = nil;
                        } else {
                            if (targetWindow) {
                                NSLog(@"✅ Window capture started successfully at 30 FPS! Window: %@ (ID: %u)", targetWindow.title, windowID);
                            } else {
                                NSLog(@"✅ Desktop capture started successfully at 30 FPS! (Window %u not found)", windowID);
                            }
                            self.isCapturing = YES;
                        }
                    }];
                } @catch (NSException *exception) {
                    NSLog(@"❌ Exception creating stream: %@", exception);
                    self.stream = nil;
                }
            });
        }];
    });
}

- (void)stopCapture {
    if (self.stream) {
        NSLog(@"🛑 Stopping current capture...");
        [self.stream stopCaptureWithCompletionHandler:^(NSError * _Nullable error) {
            if (error) {
                NSLog(@"❌ Error stopping capture: %@", error.localizedDescription);
            } else {
                NSLog(@"✅ Capture stopped");
            }
        }];
        self.stream = nil;
        self.isCapturing = NO;
        
        // Give it a moment to clean up
        [NSThread sleepForTimeInterval:0.1];
    }
}

- (NSString *)getApplicationsList {
    // Return a simple static response for desktop only
    NSMutableArray *apps = [NSMutableArray array];
    
    // Add full desktop option
    [apps addObject:@{
        @"id": @0, 
        @"name": @"Full Desktop", 
        @"type": @"desktop"
    }];
    
    NSError *jsonError;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:@{@"applications": apps} options:0 error:&jsonError];
    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

- (NSString *)getWindowsList {
    // Return cached windows list immediately - no blocking!
    return self.cachedWindowsList ?: @"[]";
}

- (NSString *)generateWindowsList {
    // Use Core Graphics to get window list (inspired by Swift script, but in Objective-C)
    CFArrayRef windowList = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    
    if (!windowList) {
        return @"[]";
    }
    
    NSMutableArray *windows = [NSMutableArray array];
    CFIndex windowCount = CFArrayGetCount(windowList);
    int windowIdCounter = 1;
    
    for (CFIndex i = 0; i < windowCount; i++) {
        CFDictionaryRef windowDict = CFArrayGetValueAtIndex(windowList, i);
        
        // Extract window information
        CFStringRef ownerName = CFDictionaryGetValue(windowDict, kCGWindowOwnerName);
        CFStringRef windowName = CFDictionaryGetValue(windowDict, kCGWindowName);
        CFDictionaryRef boundsDict = CFDictionaryGetValue(windowDict, kCGWindowBounds);
        CFNumberRef cgWindowIDRef = CFDictionaryGetValue(windowDict, kCGWindowNumber);
        
        if (!ownerName || !windowName || !boundsDict || !cgWindowIDRef) continue;
        
        NSString *ownerStr = (__bridge NSString *)ownerName;
        NSString *windowStr = (__bridge NSString *)windowName;
        
        // Skip windows without names or from system processes
        if (windowStr.length == 0 || ownerStr.length == 0) continue;
        
        // Skip certain system windows
        if ([ownerStr isEqualToString:@"WindowServer"] || 
            [ownerStr isEqualToString:@"Dock"] || 
            [ownerStr isEqualToString:@"SystemUIServer"]) continue;
        
        // Extract bounds
        CGRect bounds;
        if (!CGRectMakeWithDictionaryRepresentation(boundsDict, &bounds)) continue;
        
        // Skip windows that are too small
        if (bounds.size.width < 50 || bounds.size.height < 50) continue;
        
        // Get CGWindowID
        UInt32 cgWindowID;
        CFNumberGetValue(cgWindowIDRef, kCFNumberSInt32Type, &cgWindowID);
        
        // Create window info dictionary
        NSDictionary *windowInfo = @{
            @"id": @(windowIdCounter),
            @"cgWindowID": @(cgWindowID),
            @"title": windowStr,
            @"app": ownerStr,
            @"position": @{
                @"x": @((int)bounds.origin.x),
                @"y": @((int)bounds.origin.y)
            },
            @"size": @{
                @"width": @((int)bounds.size.width),
                @"height": @((int)bounds.size.height)
            }
        };
        
        [windows addObject:windowInfo];
        windowIdCounter++;
    }
    
    CFRelease(windowList);
    
    // Convert to JSON
    NSError *jsonError;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:windows options:0 error:&jsonError];
    
    if (jsonError) {
        return @"[]";
    }
    
    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
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

// Simple HTTP server
@interface HTTPServer : NSObject
@property (nonatomic, strong) ScreenCapture *captureServer;
@property (nonatomic, assign) int port;
@end

@implementation HTTPServer

- (instancetype)initWithPort:(int)port {
    self = [super init];
    if (self) {
        self.port = port;
        self.captureServer = [[ScreenCapture alloc] init];
    }
    return self;
}

- (void)start {
    NSLog(@"🌐 Starting HTTP server on port %d...", self.port);
    
    // Start default full desktop capture
    [self.captureServer startCaptureWithType:CaptureTypeFullDesktop targetIndex:0];
    
    NSLog(@"📝 API Endpoints:");
    NSLog(@"   GET  /apps           - List applications");
    NSLog(@"   GET  /windows        - List windows (Core Graphics)");
    NSLog(@"   GET  /frame          - Get current frame (JPEG)");
    NSLog(@"   POST /capture        - Start capture {type, index}");
    NSLog(@"   POST /click          - Send click {x, y}");
    NSLog(@"   POST /key            - Send key {key}");
    NSLog(@"   POST /stop           - Stop capture");
    
    [self startSocketServer];
}

- (void)startSocketServer {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int sockfd = socket(AF_INET, SOCK_STREAM, 0);
        if (sockfd < 0) {
            NSLog(@"❌ Error creating socket");
            return;
        }
        
        int opt = 1;
        setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
        
        struct sockaddr_in server_addr;
        server_addr.sin_family = AF_INET;
        server_addr.sin_addr.s_addr = INADDR_ANY;
        server_addr.sin_port = htons(self.port);
        
        if (bind(sockfd, (struct sockaddr*)&server_addr, sizeof(server_addr)) < 0) {
            NSLog(@"❌ Error binding socket");
            close(sockfd);
            return;
        }
        
        if (listen(sockfd, 5) < 0) {
            NSLog(@"❌ Error listening on socket");
            close(sockfd);
            return;
        }
        
        NSLog(@"✅ HTTP server listening on port %d", self.port);
        
        while (1) {
            struct sockaddr_in client_addr;
            socklen_t client_len = sizeof(client_addr);
            int client_fd = accept(sockfd, (struct sockaddr*)&client_addr, &client_len);
            
            if (client_fd < 0) {
                continue;
            }
            
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [self handleClient:client_fd];
            });
        }
    });
}

- (void)handleClient:(int)client_fd {
    char buffer[4096];
    ssize_t bytes_read = recv(client_fd, buffer, sizeof(buffer) - 1, 0);
    
    if (bytes_read <= 0) {
        close(client_fd);
        return;
    }
    
    buffer[bytes_read] = '\0';
    NSString *request = [NSString stringWithUTF8String:buffer];
    
    NSArray *lines = [request componentsSeparatedByString:@"\n"];
    if (lines.count == 0) {
        close(client_fd);
        return;
    }
    
    NSString *requestLine = lines[0];
    NSArray *parts = [requestLine componentsSeparatedByString:@" "];
    if (parts.count < 3) {
        close(client_fd);
        return;
    }
    
    NSString *method = parts[0];
    NSString *path = parts[1];
    
    // Only log non-frame requests to reduce spam
    if (![path isEqualToString:@"/frame"]) {
        NSLog(@"📨 %@ %@", method, path);
    }
    
    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/apps"]) {
        [self sendAppsListResponse:client_fd];
    } else if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/windows"]) {
        [self sendWindowsListResponse:client_fd];
    } else if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/frame"]) {
        [self sendFrameResponse:client_fd];
    } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/click"]) {
        [self handleClickRequest:client_fd request:request];
    } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/key"]) {
        [self handleKeyRequest:client_fd request:request];
    } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/capture"]) {
        [self handleCaptureRequest:client_fd request:request];
    } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/capture-window"]) {
        [self handleWindowCaptureRequest:client_fd request:request];
    } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/stop"]) {
        [self.captureServer stopCapture];
        [self sendJSONResponse:client_fd data:@{@"status": @"stopped"}];
    } else {
        [self send404Response:client_fd];
    }
    
    close(client_fd);
}

- (void)sendAppsListResponse:(int)client_fd {
    NSString *json = [self.captureServer getApplicationsList];
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    
    NSString *response = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nAccess-Control-Allow-Origin: *\r\n\r\n%@", 
                         (unsigned long)data.length, json];
    
    send(client_fd, [response UTF8String], response.length, 0);
}

- (void)sendWindowsListResponse:(int)client_fd {
    // Return cached data immediately - no blocking or async needed!
    NSString *json = [self.captureServer getWindowsList];
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    
    NSString *response = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nAccess-Control-Allow-Origin: *\r\n\r\n%@", 
                         (unsigned long)data.length, json];
    
    send(client_fd, [response UTF8String], response.length, 0);
}

- (void)sendFrameResponse:(int)client_fd {
    NSData *frameData = [self.captureServer getCurrentFrame];
    
    if (frameData.length == 0) {
        [self send404Response:client_fd];
        return;
    }
    
    NSString *header = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: %lu\r\nAccess-Control-Allow-Origin: *\r\n\r\n", 
                       (unsigned long)frameData.length];
    
    send(client_fd, [header UTF8String], header.length, 0);
    send(client_fd, frameData.bytes, frameData.length, 0);
}

- (void)handleClickRequest:(int)client_fd request:(NSString *)request {
    NSRange bodyRange = [request rangeOfString:@"\r\n\r\n"];
    if (bodyRange.location == NSNotFound) {
        [self send400Response:client_fd];
        return;
    }
    
    NSString *body = [request substringFromIndex:bodyRange.location + bodyRange.length];
    NSData *jsonData = [body dataUsingEncoding:NSUTF8StringEncoding];
    
    NSError *error;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    
    if (error || !json[@"x"] || !json[@"y"]) {
        [self send400Response:client_fd];
        return;
    }
    
    int x = [json[@"x"] intValue];
    int y = [json[@"y"] intValue];
    
    [self.captureServer performClick:x y:y];
    [self sendJSONResponse:client_fd data:@{@"status": @"clicked", @"x": @(x), @"y": @(y)}];
}

- (void)handleKeyRequest:(int)client_fd request:(NSString *)request {
    NSRange bodyRange = [request rangeOfString:@"\r\n\r\n"];
    if (bodyRange.location == NSNotFound) {
        [self send400Response:client_fd];
        return;
    }
    
    NSString *body = [request substringFromIndex:bodyRange.location + bodyRange.length];
    NSData *jsonData = [body dataUsingEncoding:NSUTF8StringEncoding];
    
    NSError *error;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    
    if (error || !json[@"key"]) {
        [self send400Response:client_fd];
        return;
    }
    
    NSString *key = json[@"key"];
    [self.captureServer performKeyPress:key];
    [self sendJSONResponse:client_fd data:@{@"status": @"key_pressed", @"key": key}];
}

- (void)handleCaptureRequest:(int)client_fd request:(NSString *)request {
    NSRange bodyRange = [request rangeOfString:@"\r\n\r\n"];
    if (bodyRange.location == NSNotFound) {
        [self send400Response:client_fd];
        return;
    }
    
    NSString *body = [request substringFromIndex:bodyRange.location + bodyRange.length];
    NSData *jsonData = [body dataUsingEncoding:NSUTF8StringEncoding];
    
    NSError *error;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    
    if (error) {
        [self send400Response:client_fd];
        return;
    }
    
    int type = [json[@"type"] intValue]; // 0=desktop, 1=app
    int index = [json[@"index"] intValue];
    
    [self.captureServer stopCapture];
    [self.captureServer startCaptureWithType:type targetIndex:index];
    
    [self sendJSONResponse:client_fd data:@{@"status": @"capture_started", @"type": @(type), @"index": @(index)}];
}

- (void)handleWindowCaptureRequest:(int)client_fd request:(NSString *)request {
    NSRange bodyRange = [request rangeOfString:@"\r\n\r\n"];
    if (bodyRange.location == NSNotFound) {
        NSLog(@"❌ No body separator found in request");
        [self send400Response:client_fd];
        return;
    }
    
    NSString *body = [request substringFromIndex:bodyRange.location + bodyRange.length];
    NSLog(@"📦 Request body: %@", body);
    NSData *jsonData = [body dataUsingEncoding:NSUTF8StringEncoding];
    
    NSError *error = nil;
    NSDictionary *json = nil;
    
    @try {
        json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    } @catch (NSException *exception) {
        NSLog(@"❌ Exception parsing JSON: %@", exception);
        [self send400Response:client_fd];
        return;
    }
    
    if (error || !json) {
        NSLog(@"❌ JSON parse error: %@", error ? error.localizedDescription : @"nil result");
        [self send400Response:client_fd];
        return;
    }
    
    NSLog(@"📌 Parsed JSON successfully: %@", json);
    
    if (!json[@"cgWindowID"]) {
        NSLog(@"❌ No cgWindowID in JSON: %@", json);
        [self send400Response:client_fd];
        return;
    }
    
    NSLog(@"📌 About to extract windowID from JSON...");
    id windowIDValue = json[@"cgWindowID"];
    NSLog(@"📌 windowID value type: %@, value: %@", [windowIDValue class], windowIDValue);
    
    UInt32 windowID = 0;
    if ([windowIDValue isKindOfClass:[NSNumber class]]) {
        windowID = [windowIDValue unsignedIntValue];
    } else {
        NSLog(@"❌ cgWindowID is not a number!");
        [self send400Response:client_fd];
        return;
    }
    
    NSLog(@"🪟 Window selection request: CGWindowID %u", windowID);
    
    if (!self.captureServer) {
        NSLog(@"❌ Capture server not initialized!");
        [self send500Response:client_fd];
        return;
    }
    
    NSLog(@"📌 Capture server exists, stopping current capture...");
    
    // Stop current capture and start window-specific capture
    @try {
        [self.captureServer stopCapture];
        NSLog(@"📌 Stop capture completed, starting window capture...");
        
        [self.captureServer startCaptureWithWindowID:windowID];
        NSLog(@"📌 Window capture started successfully");
        
        [self sendJSONResponse:client_fd data:@{@"status": @"window_capture_started", @"cgWindowID": @(windowID)}];
        NSLog(@"📌 Response sent to client");
    } @catch (NSException *exception) {
        NSLog(@"❌ Exception in window capture: %@", exception);
        [self send500Response:client_fd];
    }
}

- (void)sendJSONResponse:(int)client_fd data:(NSDictionary *)data {
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:data options:0 error:&error];
    NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    
    NSString *response = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nAccess-Control-Allow-Origin: *\r\n\r\n%@", 
                         (unsigned long)jsonData.length, json];
    
    send(client_fd, [response UTF8String], response.length, 0);
}

- (void)send404Response:(int)client_fd {
    NSString *response = @"HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found";
    send(client_fd, [response UTF8String], response.length, 0);
}

- (void)send400Response:(int)client_fd {
    NSString *response = @"HTTP/1.1 400 Bad Request\r\nContent-Length: 11\r\n\r\nBad Request";
    send(client_fd, [response UTF8String], response.length, 0);
}

- (void)send500Response:(int)client_fd {
    NSString *response = @"HTTP/1.1 500 Internal Server Error\r\nContent-Length: 21\r\n\r\nInternal Server Error";
    send(client_fd, [response UTF8String], response.length, 0);
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSLog(@"🔥 ScreenCaptureKit HTTP Server v7 Starting...");
        
        int port = 8080;
        if (argc > 1) {
            port = atoi(argv[1]);
        }
        
        BOOL hasScreenPermission = CGPreflightScreenCaptureAccess();
        BOOL hasAccessibilityPermission = AXIsProcessTrusted();
        
        NSLog(@"📋 Permission Status:");
        NSLog(@"   Screen Recording: %@", hasScreenPermission ? @"✅ GRANTED" : @"❌ DENIED");
        NSLog(@"   Accessibility: %@", hasAccessibilityPermission ? @"✅ GRANTED" : @"❌ DENIED");
        
        if (!hasScreenPermission) {
            NSLog(@"🔒 Screen recording permission required!");
            CGRequestScreenCaptureAccess();
        }
        
        HTTPServer *server = [[HTTPServer alloc] initWithPort:port];
        [server start];
        
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}