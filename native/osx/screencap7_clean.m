#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>
// VP9 encoder removed - using High Quality JPEG instead

typedef enum {
    CaptureTypeFullDesktop = 0,
    CaptureTypeApplication = 1,
    CaptureTypeWindow = 2
} CaptureType;

@interface ScreenCapture : NSObject <SCStreamOutput, SCStreamDelegate>
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
@property (nonatomic, assign) BOOL useVP9Mode;
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
        
        // Configure capture size
        config.width = (int)captureSize.width;
        config.height = (int)captureSize.height;
        
        // Log capture mode and size for debugging
        if (self.captureType == CaptureTypeWindow) {
            NSLog(@"🔧 Window capture: Size %zux%zu", config.width, config.height);
        } else {
            NSLog(@"🔧 Desktop capture: Size %zux%zu", config.width, config.height);
        }
        
        config.queueDepth = 6;
        config.pixelFormat = kCVPixelFormatType_32BGRA;
        config.colorSpaceName = kCGColorSpaceSRGB;
        config.showsCursor = YES;
        config.minimumFrameInterval = CMTimeMake(1, 30); // 30 FPS
        
        // Enable headless capture for locked screens and closed lids
        if (@available(macOS 13.0, *)) {
            config.capturesAudio = NO;
            config.sampleRate = 0;
            config.channelCount = 0;
            // These experimental settings may help with headless capture
            NSLog(@"🔧 Attempting headless capture configuration...");
        }
        
        NSLog(@"🔧 Configured stream for headless capture (locked screen / lid closed support)");
        
        // VP9/High Quality mode - use better JPEG settings
        if (self.useVP9Mode) {
            NSLog(@"🚀 High Quality mode enabled: %zux%zu", config.width, config.height);
        }
        
        // Create stream with error delegate
        self.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
        
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
    [self performClick:x y:y targetWindowID:0];
}

- (void)performClick:(int)x y:(int)y targetWindowID:(UInt32)windowID {
    [self performClick:x y:y targetWindowID:windowID activateWindow:YES];
}

- (void)performClick:(int)x y:(int)y targetWindowID:(UInt32)windowID activateWindow:(BOOL)activate {
    NSLog(@"🖱️ Clicking at %d,%d (target window: %u, activate: %@)", x, y, windowID, activate ? @"YES" : @"NO");
    
    @try {
        // Check accessibility permissions
        if (!AXIsProcessTrusted()) {
            NSLog(@"❌ No accessibility permission for mouse events!");
            NSLog(@"🔒 Please enable accessibility for this app in System Preferences > Privacy & Security > Accessibility");
            return;
        }
        
        NSLog(@"✅ Accessibility permission verified");
        
        CGPoint clickPoint = CGPointMake(x, y);
        
        // If we have a target window, bring it to front (coordinates are already scaled properly)
        if (windowID != 0) {
            NSLog(@"🎯 Targeting specific window ID: %u at coordinates %d,%d", windowID, x, y);
            
            // Always activate the window to bring it to front
            [self activateWindowIfNeeded:windowID];
            
            // Don't adjust coordinates - they're already scaled correctly from the server
            NSLog(@"🎯 Using provided coordinates directly (already scaled): %.0f,%.0f", clickPoint.x, clickPoint.y);
        }
        
        // Use window-specific events if we have a target window
        if (windowID != 0) {
            NSLog(@"🎯 Sending window-specific click events to window %u", windowID);
            
            // Try to find the specific window element and click it directly
            pid_t targetPID = [self getProcessIDForWindowID:windowID];
            if (targetPID > 0) {
                AXUIElementRef appElement = AXUIElementCreateApplication(targetPID);
                if (appElement) {
                    CFArrayRef windows;
                    AXError result = AXUIElementCopyAttributeValues(appElement, kAXWindowsAttribute, 0, 100, &windows);
                    
                    if (result == kAXErrorSuccess && windows) {
                        CFIndex windowCount = CFArrayGetCount(windows);
                        
                        for (CFIndex j = 0; j < windowCount; j++) {
                            AXUIElementRef windowElement = (AXUIElementRef)CFArrayGetValueAtIndex(windows, j);
                            
                            // Get window position to match with our CGWindowID
                            CFTypeRef positionValue;
                            if (AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute, &positionValue) == kAXErrorSuccess) {
                                CGPoint windowPos;
                                if (AXValueGetValue(positionValue, kAXValueCGPointType, &windowPos)) {
                                    // Check if this matches our target window position
                                    CFArrayRef cgWindows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
                                    if (cgWindows) {
                                        CFIndex cgCount = CFArrayGetCount(cgWindows);
                                        for (CFIndex k = 0; k < cgCount; k++) {
                                            CFDictionaryRef cgWindow = (CFDictionaryRef)CFArrayGetValueAtIndex(cgWindows, k);
                                            CFNumberRef cgWindowNumber = (CFNumberRef)CFDictionaryGetValue(cgWindow, kCGWindowNumber);
                                            UInt32 cgID;
                                            CFNumberGetValue(cgWindowNumber, kCFNumberSInt32Type, &cgID);
                                            
                                            if (cgID == windowID) {
                                                CFDictionaryRef bounds = (CFDictionaryRef)CFDictionaryGetValue(cgWindow, kCGWindowBounds);
                                                if (bounds) {
                                                    CGRect cgRect;
                                                    CGRectMakeWithDictionaryRepresentation(bounds, &cgRect);
                                                    
                                                    // If positions match (within 5 pixels), this is our window
                                                    if (fabs(windowPos.x - cgRect.origin.x) < 5 && fabs(windowPos.y - cgRect.origin.y) < 5) {
                                                        // Found the correct window - bring it to front
                                                        AXUIElementSetAttributeValue(windowElement, kAXMainAttribute, kCFBooleanTrue);
                                                        AXUIElementSetAttributeValue(windowElement, kAXFocusedAttribute, kCFBooleanTrue);
                                                        usleep(100000); // 100ms delay for window to focus
                                                        
                                                        NSLog(@"✅ Brought specific window to front, using original coordinates");
                                                        
                                                        CFRelease(cgWindows);
                                                        
                                                        // Use the original click coordinates since the window is now focused
                                                        CGPoint originalPoint = CGPointMake(x, y);
                                                        CGEventRef mouseDown = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, originalPoint, kCGMouseButtonLeft);
                                                        CGEventRef mouseUp = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, originalPoint, kCGMouseButtonLeft);
                                                        
                                                        if (mouseDown && mouseUp) {
                                                            NSLog(@"📤 Posting targeted click at original coordinates %d,%d", x, y);
                                                            CGEventPost(kCGHIDEventTap, mouseDown);
                                                            usleep(10000); // 10ms between down and up
                                                            CGEventPost(kCGHIDEventTap, mouseUp);
                                                            
                                                            CFRelease(mouseDown);
                                                            CFRelease(mouseUp);
                                                            NSLog(@"✅ Window-specific click completed successfully");
                                                        }
                                                        
                                                        goto cleanup_and_return;
                                                    }
                                                }
                                            }
                                        }
                                        CFRelease(cgWindows);
                                    }
                                }
                                CFRelease(positionValue);
                            }
                        }
                        CFRelease(windows);
                    }
                    CFRelease(appElement);
                }
            }
            
            NSLog(@"⚠️ Window-specific click failed, falling back to global events");
        }
        
        // Fallback to global events
        CGEventRef mouseDown = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, clickPoint, kCGMouseButtonLeft);
        CGEventRef mouseUp = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, clickPoint, kCGMouseButtonLeft);
        
        NSLog(@"📝 Created mouse events: down=%p, up=%p", mouseDown, mouseUp);
        
        if (mouseDown && mouseUp) {
            NSLog(@"📤 Posting global mouse events...");
            CGEventPost(kCGHIDEventTap, mouseDown);
            CGEventPost(kCGHIDEventTap, mouseUp);
            
            CFRelease(mouseDown);
            CFRelease(mouseUp);
            NSLog(@"✅ Click executed and events released");
        } else {
            NSLog(@"❌ Failed to create mouse events");
            if (mouseDown) CFRelease(mouseDown);
            if (mouseUp) CFRelease(mouseUp);
        }
        
        cleanup_and_return:;
    } @catch (NSException *exception) {
        NSLog(@"❌ Exception in performClick: %@", exception);
    }
}

- (pid_t)getProcessIDForWindowID:(UInt32)windowID {
    CFArrayRef windowList = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    pid_t targetPID = 0;
    
    if (windowList) {
        CFIndex count = CFArrayGetCount(windowList);
        for (CFIndex i = 0; i < count; i++) {
            CFDictionaryRef window = (CFDictionaryRef)CFArrayGetValueAtIndex(windowList, i);
            CFNumberRef windowNumber = (CFNumberRef)CFDictionaryGetValue(window, kCGWindowNumber);
            
            UInt32 currentWindowID;
            CFNumberGetValue(windowNumber, kCFNumberSInt32Type, &currentWindowID);
            
            if (currentWindowID == windowID) {
                CFNumberRef ownerPID = (CFNumberRef)CFDictionaryGetValue(window, kCGWindowOwnerPID);
                if (ownerPID) {
                    CFNumberGetValue(ownerPID, kCFNumberSInt32Type, &targetPID);
                }
                break;
            }
        }
        CFRelease(windowList);
    }
    
    return targetPID;
}

- (void)activateWindowIfNeeded:(UInt32)windowID {
    NSLog(@"🎯 Attempting to activate specific window %u for better event delivery", windowID);
    
    // First try to bring the specific window to front using Core Graphics
    CFArrayRef windowList = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    if (windowList) {
        CFIndex count = CFArrayGetCount(windowList);
        for (CFIndex i = 0; i < count; i++) {
            CFDictionaryRef window = (CFDictionaryRef)CFArrayGetValueAtIndex(windowList, i);
            CFNumberRef windowNumber = (CFNumberRef)CFDictionaryGetValue(window, kCGWindowNumber);
            
            UInt32 currentWindowID;
            CFNumberGetValue(windowNumber, kCFNumberSInt32Type, &currentWindowID);
            
            if (currentWindowID == windowID) {
                // Found our target window - get its info
                CFStringRef windowTitle = (CFStringRef)CFDictionaryGetValue(window, kCGWindowName);
                CFStringRef ownerName = (CFStringRef)CFDictionaryGetValue(window, kCGWindowOwnerName);
                
                NSString *title = windowTitle ? (__bridge NSString *)windowTitle : @"Untitled";
                NSString *owner = ownerName ? (__bridge NSString *)ownerName : @"Unknown";
                NSLog(@"🎯 Found target window: '%@' from '%@'", title, owner);
                
                // Get the process ID and activate the application first
                pid_t targetPID = [self getProcessIDForWindowID:windowID];
                if (targetPID > 0) {
                    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:targetPID];
                    if (app) {
                        NSLog(@"🎯 Activating application: %@", app.localizedName);
                        [app activateWithOptions:0];
                        usleep(200000); // 200ms - longer wait for app activation
                    }
                }
                
                // Now try to bring this specific window to front using accessibility
                AXUIElementRef appElement = AXUIElementCreateApplication(targetPID);
                if (appElement) {
                    CFArrayRef windows;
                    AXError result = AXUIElementCopyAttributeValues(appElement, kAXWindowsAttribute, 0, 100, &windows);
                    
                    if (result == kAXErrorSuccess && windows) {
                        CFIndex windowCount = CFArrayGetCount(windows);
                        NSLog(@"🔍 Found %ld windows in app, looking for window %u", windowCount, windowID);
                        
                        for (CFIndex j = 0; j < windowCount; j++) {
                            AXUIElementRef windowElement = (AXUIElementRef)CFArrayGetValueAtIndex(windows, j);
                            
                            // Try to bring this window to front
                            AXError frontResult = AXUIElementSetAttributeValue(windowElement, kAXMainAttribute, kCFBooleanTrue);
                            AXError focusResult = AXUIElementSetAttributeValue(windowElement, kAXFocusedAttribute, kCFBooleanTrue);
                            
                            if (frontResult == kAXErrorSuccess) {
                                NSLog(@"✅ Successfully brought window to front using AX");
                                usleep(100000); // 100ms
                                break;
                            }
                        }
                        CFRelease(windows);
                    }
                    CFRelease(appElement);
                }
                break;
            }
        }
        CFRelease(windowList);
    }
    
    NSLog(@"✅ Window activation sequence completed");
}

- (void)performKeyPress:(NSString *)key {
    [self performKeyPress:key targetWindowID:0];
}

- (void)performKeyPress:(NSString *)key targetWindowID:(UInt32)windowID {
    NSLog(@"⌨️ Key press: %@ (target window: %u)", key, windowID);
    
    if (!key || key.length == 0) {
        NSLog(@"❌ Empty key string");
        return;
    }
    
    // Check accessibility permissions
    if (!AXIsProcessTrusted()) {
        NSLog(@"❌ No accessibility permission for keyboard events!");
        NSLog(@"🔒 Please enable accessibility for this app in System Preferences > Privacy & Security > Accessibility");
        return;
    }
    
    // If targeting a specific window, bring it to front first
    if (windowID != 0) {
        NSLog(@"🎯 Targeting specific window ID: %u", windowID);
        [self activateWindowIfNeeded:windowID];
    }
    
    CGKeyCode keyCode = 0;
    unichar character = [key characterAtIndex:0];
    NSLog(@"🔤 Processing character: '%c' (unicode: %d)", character, character);

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
        case 'o': case 'O': keyCode = 31; break;
        case 'u': case 'U': keyCode = 32; break;
        case '[': keyCode = 33; break;
        case 'i': case 'I': keyCode = 34; break;
        case 'p': case 'P': keyCode = 35; break;
        case 'l': case 'L': keyCode = 37; break;
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
    
    NSLog(@"📤 Creating keyboard events for keyCode: %d", keyCode);
    
    // Create key events synchronously and post them
    CGEventRef keyDown = CGEventCreateKeyboardEvent(NULL, keyCode, true);
    CGEventRef keyUp = CGEventCreateKeyboardEvent(NULL, keyCode, false);
    
    NSLog(@"📝 Created keyboard events: down=%p, up=%p", keyDown, keyUp);
    
    if (keyDown && keyUp) {
        // Always use global events now that the target window is in focus
        NSLog(@"📤 Posting global keyboard events...");
        CGEventPost(kCGHIDEventTap, keyDown);
        CGEventPost(kCGHIDEventTap, keyUp);
        
        CFRelease(keyDown);
        CFRelease(keyUp);
        NSLog(@"✅ Key press completed and events released");
    } else {
        NSLog(@"❌ Failed to create keyboard events");
        if (keyDown) CFRelease(keyDown);
        if (keyUp) CFRelease(keyUp);
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
    
    // Reset frame failure counter when we get a successful frame
    static int frameFailureCount = 0;
    frameFailureCount = 0;
    
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
                // Set JPEG quality - higher for VP9/High Quality mode
                float quality = self.useVP9Mode ? 0.95 : 0.75;
                int maxSize = self.useVP9Mode ? 3840 : 1920; // Full resolution in HQ mode
                
                NSDictionary *options = @{
                    (__bridge NSString*)kCGImageDestinationLossyCompressionQuality: @(quality),
                    (__bridge NSString*)kCGImageDestinationImageMaxPixelSize: @(maxSize)
                };
                
                CGImageDestinationAddImage(destination, cgImage, (__bridge CFDictionaryRef)options);
                CGImageDestinationFinalize(destination);
                CFRelease(destination);
                
                // Store JPEG data for HTTP server
                @synchronized(self.currentFrame) {
                    [self.currentFrame setData:jpegData];
                }
                
                // VP9/High Quality mode provides better JPEG quality and full resolution
                
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

// getCurrentEncodedFrame method removed - using High Quality JPEG instead

- (void)startCaptureWithType:(CaptureType)captureType targetIndex:(int)targetIndex {
    [self startCaptureWithType:captureType targetIndex:targetIndex vp9Mode:NO];
}

- (void)startCaptureWithType:(CaptureType)captureType targetIndex:(int)targetIndex vp9Mode:(BOOL)useVP9 {
    self.captureType = captureType;
    self.targetIndex = targetIndex;
    self.useVP9Mode = useVP9;
    
    if (useVP9) {
        NSLog(@"🚀 Starting capture with High Quality mode enabled");
    } else {
        NSLog(@"📸 Starting capture with standard MJPEG mode");
    }
    
    [self setupCapture];
}

- (void)startCaptureWithWindowID:(UInt32)windowID {
    [self startCaptureWithWindowID:windowID vp9Mode:NO];
}

- (void)startCaptureWithWindowID:(UInt32)windowID vp9Mode:(BOOL)useVP9 {
    NSLog(@"🎯 startCaptureWithWindowID called with ID: %u, VP9: %@", windowID, useVP9 ? @"YES" : @"NO");
    
    // Special method for capturing specific windows by CGWindowID
    self.captureType = CaptureTypeWindow;
    self.targetIndex = (int)windowID; // Store windowID in targetIndex
    self.useVP9Mode = useVP9;
    
    if (useVP9) {
        NSLog(@"🚀 Window capture with High Quality mode enabled");
    } else {
        NSLog(@"📸 Window capture with standard MJPEG mode");
    }
    
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
            
            // Enable headless capture for locked screens and closed lids
            if (@available(macOS 13.0, *)) {
                config.capturesAudio = NO;
                config.sampleRate = 0;
                config.channelCount = 0;
                // These experimental settings may help with headless capture
                NSLog(@"🔧 Attempting headless window capture configuration...");
            }
            
            NSLog(@"🔧 Configured window stream for headless capture");
            
            // Create new stream on main queue
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    self.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
                    
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
    // Generate fresh windows list each time to avoid caching issues
    NSString *freshList = [self generateWindowsList];
    return freshList ?: @"[]";
}

- (NSString *)generateWindowsList {
    CFArrayRef windowList = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    
    if (!windowList) {
        return @"[]";
    }
    
    NSMutableArray *windows = [NSMutableArray array];
    CFIndex windowCount = CFArrayGetCount(windowList);
    int windowIdCounter = 1;
    
    for (CFIndex i = 0; i < windowCount; i++) {
        CFDictionaryRef windowDict = CFArrayGetValueAtIndex(windowList, i);
        
        CFStringRef ownerName = CFDictionaryGetValue(windowDict, kCGWindowOwnerName);
        CFStringRef windowName = CFDictionaryGetValue(windowDict, kCGWindowName);
        CFDictionaryRef boundsDict = CFDictionaryGetValue(windowDict, kCGWindowBounds);
        CFNumberRef cgWindowIDRef = CFDictionaryGetValue(windowDict, kCGWindowNumber);
        
        if (!ownerName || !windowName || !boundsDict || !cgWindowIDRef) continue;
        
        NSString *ownerStr = (__bridge NSString *)ownerName;
        NSString *windowStr = (__bridge NSString *)windowName;
        
        // Skip windows without names or from system processes
        if (windowStr.length == 0 || ownerStr.length == 0) continue;
        
        // Extract bounds
        CGRect bounds;
        if (!CGRectMakeWithDictionaryRepresentation(boundsDict, &bounds)) continue;
        
        // Skip windows that are too small
        if (bounds.size.width < 50 || bounds.size.height < 50) continue;
        
        // Skip certain system windows
        if ([ownerStr isEqualToString:@"WindowServer"] || 
            [ownerStr isEqualToString:@"Dock"] || 
            [ownerStr isEqualToString:@"SystemUIServer"]) continue;
        
        // Get CGWindowID safely
        UInt32 cgWindowID = 0;
        if (cgWindowIDRef) {
            CFNumberGetValue(cgWindowIDRef, kCFNumberSInt32Type, &cgWindowID);
        }
        
        // Limit to 30 windows to avoid browser hanging
        if (windowIdCounter > 30) break;
        
        // Create window info dictionary with safer NSNumber creation
        @try {
            NSDictionary *windowInfo = @{
                @"id": [NSNumber numberWithInt:windowIdCounter],
                @"cgWindowID": [NSNumber numberWithUnsignedInt:cgWindowID],
                @"title": windowStr ?: @"",
                @"app": ownerStr ?: @"",
                @"position": @{
                    @"x": [NSNumber numberWithInt:(int)bounds.origin.x],
                    @"y": [NSNumber numberWithInt:(int)bounds.origin.y]
                },
                @"size": @{
                    @"width": [NSNumber numberWithInt:(int)bounds.size.width],
                    @"height": [NSNumber numberWithInt:(int)bounds.size.height]
                }
            };
            
            [windows addObject:windowInfo];
            windowIdCounter++;
        } @catch (NSException *exception) {
            // Skip this window if there's an error creating the dictionary
            continue;
        }
    }
    
    CFRelease(windowList);
    
    // Convert to JSON safely
    @try {
        NSError *jsonError = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:windows options:0 error:&jsonError];
        
        if (jsonError || !jsonData) {
            return @"[]";
        }
        
        return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    } @catch (NSException *exception) {
        return @"[]";
    }
}

#pragma mark - SCStreamDelegate

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    NSLog(@"🚨 Stream stopped with error: %@", error.localizedDescription);
    
    if (error.code == -3801) { // SCStreamErrorDisplayNotFound
        NSLog(@"🔒 Display not available (likely locked/sleeping). Attempting to continue with last frame...");
        
        // Keep serving the last captured frame
        // Don't restart the stream immediately as it may fail again
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSLog(@"🔄 Attempting to restart capture after display lock...");
            [self setupCapture];
        });
    } else {
        NSLog(@"❌ Stream error: %ld - %@", (long)error.code, error.localizedDescription);
        
        // Try to restart the stream after a delay
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSLog(@"🔄 Attempting to restart stream...");
            [self setupCapture];
        });
    }
}

- (void)streamDidBecomeInvalid:(SCStream *)stream {
    NSLog(@"⚠️ Stream became invalid");
    
    if (stream == self.stream) {
        self.stream = nil;
        self.isCapturing = NO;
        
        // Try to restart after a delay
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSLog(@"🔄 Restarting capture after stream invalidation...");
            [self setupCapture];
        });
    }
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
    NSLog(@"   GET  /display        - Get display info (resolution, scaling)");
    NSLog(@"   GET  /frame          - Get current frame (JPEG)");
    NSLog(@"   POST /capture        - Start capture {type, index}");
    NSLog(@"   POST /click          - Send click {x, y}");
    NSLog(@"   POST /click-window   - Send click to window {x, y, cgWindowID}");
    NSLog(@"   POST /click-background - Send click to background window {x, y, cgWindowID}");
    NSLog(@"   POST /key            - Send key {key}");
    NSLog(@"   POST /key-window     - Send key to window {key, cgWindowID}");
    NSLog(@"   POST /key-background - Send key to background window {key, cgWindowID}");
    NSLog(@"   POST /screenshot     - Get window screenshot {cgWindowID}");
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
    NSString *fullPath = parts[1];
    
    // Strip query string from path (e.g., "/frame?123" -> "/frame")
    NSString *path = [fullPath componentsSeparatedByString:@"?"][0];
    
    // Only log non-frame and non-display requests to reduce spam
    if (![path isEqualToString:@"/frame"] && ![path isEqualToString:@"/display"]) {
        NSLog(@"📨 %@ %@", method, fullPath);
    }
    
    if ([method isEqualToString:@"GET"] && ([path isEqualToString:@"/"] || [path isEqualToString:@"/index.html"])) {
        [self sendWebUIResponse:client_fd];
    } else if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/apps"]) {
        [self sendAppsListResponse:client_fd];
    } else if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/windows"]) {
        [self sendWindowsListResponse:client_fd];
    } else if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/display"]) {
        [self sendDisplayInfoResponse:client_fd];
    } else if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/frame"]) {
        [self sendFrameResponse:client_fd];
    // VP9 frame endpoint removed - using High Quality JPEG instead
    } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/click"]) {
        [self handleClickRequest:client_fd request:request];
    } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/click-window"]) {
        [self handleWindowClickRequest:client_fd request:request];
    } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/key"]) {
        [self handleKeyRequest:client_fd request:request];
    } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/key-window"]) {
        [self handleWindowKeyRequest:client_fd request:request];
    } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/capture"]) {
        [self handleCaptureRequest:client_fd request:request];
    } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/capture-window"]) {
        [self handleWindowCaptureRequest:client_fd request:request];
    } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/stop"]) {
        [self.captureServer stopCapture];
        [self sendJSONResponse:client_fd data:@{@"status": @"stopped"}];
    } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/screenshot"]) {
        [self handleScreenshotRequest:client_fd request:request];
    } else if ([method isEqualToString:@"OPTIONS"]) {
        [self sendCORSResponse:client_fd];
    } else {
        [self send404Response:client_fd];
    }
    
    close(client_fd);
}

- (void)sendAppsListResponse:(int)client_fd {
    NSString *json = [self.captureServer getApplicationsList];
    NSData *jsonData = [json dataUsingEncoding:NSUTF8StringEncoding];
    
    NSString *headers = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nAccess-Control-Allow-Origin: *\r\n\r\n", 
                        (unsigned long)jsonData.length];
    
    send(client_fd, [headers UTF8String], headers.length, 0);
    send(client_fd, jsonData.bytes, jsonData.length, 0);
}

- (void)sendWindowsListResponse:(int)client_fd {
    NSString *json = [self.captureServer getWindowsList];
    NSData *jsonData = [json dataUsingEncoding:NSUTF8StringEncoding];
    
    NSString *headers = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nAccess-Control-Allow-Origin: *\r\n\r\n", 
                        (unsigned long)jsonData.length];
    
    // Send headers and body separately to ensure correct Content-Length
    send(client_fd, [headers UTF8String], headers.length, 0);
    send(client_fd, jsonData.bytes, jsonData.length, 0);
}

- (void)sendDisplayInfoResponse:(int)client_fd {
    // Get primary display dimensions
    CGDirectDisplayID displayID = CGMainDisplayID();
    size_t physicalWidth = CGDisplayPixelsWide(displayID);
    size_t physicalHeight = CGDisplayPixelsHigh(displayID);
    
    // Get display bounds (logical coordinates for mouse events)
    CGRect bounds = CGDisplayBounds(displayID);
    
    // For clicks, we need to use the LOGICAL coordinate system, not physical pixels
    size_t clickWidth = (size_t)bounds.size.width;
    size_t clickHeight = (size_t)bounds.size.height;
    
    NSLog(@"🔍 Display info: Physical=%zux%zu, Logical=%.0fx%.0f (for clicks), Scale=%.1fx", 
          physicalWidth, physicalHeight, bounds.size.width, bounds.size.height, (double)physicalWidth/bounds.size.width);
    
    NSDictionary *displayInfo = @{
        @"width": @(clickWidth),        // Use logical coordinates for clicking
        @"height": @(clickHeight),      // Use logical coordinates for clicking
        @"physicalWidth": @(physicalWidth),
        @"physicalHeight": @(physicalHeight),
        @"boundsWidth": @(bounds.size.width),
        @"boundsHeight": @(bounds.size.height),
        @"scaleFactor": @((double)physicalWidth / bounds.size.width)
    };
    
    NSError *jsonError;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:displayInfo options:0 error:&jsonError];
    NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    
    NSString *response = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nAccess-Control-Allow-Origin: *\r\n\r\n%@", 
                         (unsigned long)jsonData.length, json];
    
    send(client_fd, [response UTF8String], response.length, 0);
}

- (void)sendFrameResponse:(int)client_fd {
    NSData *frameData = [self.captureServer getCurrentFrame];
    
    NSLog(@"🖼️ Frame request: frameData.length = %lu, isCapturing = %@", 
          frameData.length, self.captureServer.isCapturing ? @"YES" : @"NO");
    
    if (frameData.length == 0) {
        NSLog(@"❌ No frame data available - sending 404");
        [self send404Response:client_fd];
        return;
    }
    
    NSString *header = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: %lu\r\nAccess-Control-Allow-Origin: *\r\n\r\n", 
                       (unsigned long)frameData.length];
    
    send(client_fd, [header UTF8String], header.length, 0);
    send(client_fd, frameData.bytes, frameData.length, 0);
}

// VP9 frame response method removed - using High Quality JPEG instead

- (void)handleClickRequest:(int)client_fd request:(NSString *)request {
    NSRange bodyRange = [request rangeOfString:@"\r\n\r\n"];
    if (bodyRange.location == NSNotFound) {
        NSLog(@"❌ Click request: No body separator found");
        [self send400Response:client_fd];
        return;
    }
    
    NSString *body = [request substringFromIndex:bodyRange.location + bodyRange.length];
    NSLog(@"📦 Click request body: %@", body);
    NSData *jsonData = [body dataUsingEncoding:NSUTF8StringEncoding];
    
    NSError *error = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    
    if (error || !json) {
        NSLog(@"❌ Click JSON parse error: %@", error ? [error description] : @"nil result");
        [self send400Response:client_fd];
        return;
    }
    
    if (!json[@"x"] || !json[@"y"]) {
        NSLog(@"❌ Click request missing x or y: %@", json);
        [self send400Response:client_fd];
        return;
    }
    
    int x = [json[@"x"] intValue];
    int y = [json[@"y"] intValue];
    NSLog(@"🖱️ Click at (%d, %d)", x, y);
    
    [self.captureServer performClick:x y:y];
    [self sendJSONResponse:client_fd data:@{@"status": @"clicked", @"x": @(x), @"y": @(y)}];
}

- (void)handleKeyRequest:(int)client_fd request:(NSString *)request {
    NSRange bodyRange = [request rangeOfString:@"\r\n\r\n"];
    if (bodyRange.location == NSNotFound) {
        NSLog(@"❌ Key request: No body separator found");
        [self send400Response:client_fd];
        return;
    }
    
    NSString *body = [request substringFromIndex:bodyRange.location + bodyRange.length];
    NSLog(@"📦 Key request body: %@", body);
    NSData *jsonData = [body dataUsingEncoding:NSUTF8StringEncoding];
    
    NSError *error = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    
    if (error || !json) {
        NSLog(@"❌ Key JSON parse error: %@", error ? [error description] : @"nil result");
        [self send400Response:client_fd];
        return;
    }
    
    if (!json[@"key"]) {
        NSLog(@"❌ Key request missing key field: %@", json);
        [self send400Response:client_fd];
        return;
    }
    
    NSString *key = json[@"key"];
    NSLog(@"⌨️ Key press: %@", key);
    
    @try {
        [self.captureServer performKeyPress:key];
        [self sendJSONResponse:client_fd data:@{@"status": @"key_pressed", @"key": key}];
        NSLog(@"✅ Key press response sent");
    } @catch (NSException *exception) {
        NSLog(@"❌ Exception in key press: %@", exception);
        [self send500Response:client_fd];
    }
}

- (void)handleWindowClickRequest:(int)client_fd request:(NSString *)request {
    NSRange bodyRange = [request rangeOfString:@"\r\n\r\n"];
    if (bodyRange.location == NSNotFound) {
        NSLog(@"❌ Window click request: No body separator found");
        [self send400Response:client_fd];
        return;
    }
    
    NSString *body = [request substringFromIndex:bodyRange.location + bodyRange.length];
    NSLog(@"📦 Window click request body: %@", body);
    NSData *jsonData = [body dataUsingEncoding:NSUTF8StringEncoding];
    
    NSError *error = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    
    if (error || !json) {
        NSLog(@"❌ Window click JSON parse error: %@", error ? [error description] : @"nil result");
        [self send400Response:client_fd];
        return;
    }
    
    if (!json[@"x"] || !json[@"y"] || !json[@"cgWindowID"]) {
        NSLog(@"❌ Window click request missing x, y, or cgWindowID: %@", json);
        [self send400Response:client_fd];
        return;
    }
    
    int x = [json[@"x"] intValue];
    int y = [json[@"y"] intValue];
    UInt32 windowID = [json[@"cgWindowID"] unsignedIntValue];
    NSLog(@"🖱️ Window click at (%d, %d) targeting window %u", x, y, windowID);
    
    @try {
        [self.captureServer performClick:x y:y targetWindowID:windowID];
        [self sendJSONResponse:client_fd data:@{@"status": @"clicked", @"x": @(x), @"y": @(y), @"cgWindowID": @(windowID)}];
        NSLog(@"✅ Window click response sent");
    } @catch (NSException *exception) {
        NSLog(@"❌ Exception in window click: %@", exception);
        [self send500Response:client_fd];
    }
}

- (void)handleWindowKeyRequest:(int)client_fd request:(NSString *)request {
    NSRange bodyRange = [request rangeOfString:@"\r\n\r\n"];
    if (bodyRange.location == NSNotFound) {
        NSLog(@"❌ Window key request: No body separator found");
        [self send400Response:client_fd];
        return;
    }
    
    NSString *body = [request substringFromIndex:bodyRange.location + bodyRange.length];
    NSLog(@"📦 Window key request body: %@", body);
    NSData *jsonData = [body dataUsingEncoding:NSUTF8StringEncoding];
    
    NSError *error = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    
    if (error || !json) {
        NSLog(@"❌ Window key JSON parse error: %@", error ? [error description] : @"nil result");
        [self send400Response:client_fd];
        return;
    }
    
    if (!json[@"key"] || !json[@"cgWindowID"]) {
        NSLog(@"❌ Window key request missing key or cgWindowID: %@", json);
        [self send400Response:client_fd];
        return;
    }
    
    NSString *key = json[@"key"];
    UInt32 windowID = [json[@"cgWindowID"] unsignedIntValue];
    NSLog(@"⌨️ Window key press: %@ targeting window %u", key, windowID);
    
    @try {
        [self.captureServer performKeyPress:key targetWindowID:windowID];
        [self sendJSONResponse:client_fd data:@{@"status": @"key_pressed", @"key": key, @"cgWindowID": @(windowID)}];
        NSLog(@"✅ Window key press response sent");
    } @catch (NSException *exception) {
        NSLog(@"❌ Exception in window key press: %@", exception);
        [self send500Response:client_fd];
    }
}

- (void)handleCaptureRequest:(int)client_fd request:(NSString *)request {
    NSRange bodyRange = [request rangeOfString:@"\r\n\r\n"];
    if (bodyRange.location == NSNotFound) {
        [self send400Response:client_fd];
        return;
    }
    
    NSString *body = [request substringFromIndex:bodyRange.location + bodyRange.length];
    NSData *jsonData = [body dataUsingEncoding:NSUTF8StringEncoding];
    
    NSError *error = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    
    if (error) {
        [self send400Response:client_fd];
        return;
    }
    
    int type = [json[@"type"] intValue]; // 0=desktop, 1=app
    int index = [json[@"index"] intValue];
    BOOL vp9Mode = [json[@"vp9"] boolValue]; // VP9 hardware acceleration
    
    [self.captureServer stopCapture];
    [self.captureServer startCaptureWithType:type targetIndex:index vp9Mode:vp9Mode];
    
    NSString *modeStr = vp9Mode ? @"High Quality" : @"Standard";
    [self sendJSONResponse:client_fd data:@{
        @"status": @"capture_started", 
        @"type": @(type), 
        @"index": @(index),
        @"mode": modeStr
    }];
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
    
    BOOL vp9Mode = [json[@"vp9"] boolValue]; // VP9 hardware acceleration
    
    NSLog(@"🪟 Window selection request: CGWindowID %u, HQ: %@", windowID, vp9Mode ? @"YES" : @"NO");
    
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
        
        [self.captureServer startCaptureWithWindowID:windowID vp9Mode:vp9Mode];
        NSLog(@"📌 Window capture started successfully");
        
        NSString *modeStr = vp9Mode ? @"High Quality" : @"Standard";
        [self sendJSONResponse:client_fd data:@{
            @"status": @"window_capture_started", 
            @"cgWindowID": @(windowID),
            @"mode": modeStr
        }];
        NSLog(@"📌 Response sent to client");
    } @catch (NSException *exception) {
        NSLog(@"❌ Exception in window capture: %@", exception);
        [self send500Response:client_fd];
    }
}

- (void)handleScreenshotRequest:(int)client_fd request:(NSString *)request {
    NSRange bodyRange = [request rangeOfString:@"\r\n\r\n"];
    if (bodyRange.location == NSNotFound) {
        [self send400Response:client_fd];
        return;
    }
    
    NSString *body = [request substringFromIndex:bodyRange.location + bodyRange.length];
    NSData *jsonData = [body dataUsingEncoding:NSUTF8StringEncoding];
    
    NSError *error = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
    
    if (error || !json[@"cgWindowID"]) {
        [self send400Response:client_fd];
        return;
    }
    
    UInt32 windowID = [json[@"cgWindowID"] unsignedIntValue];
    NSLog(@"📸 Taking screenshot of window %u using screencapture command", windowID);
    
    // Use system screencapture command - simple and always works
    NSString *tempFile = [NSString stringWithFormat:@"/tmp/window_%u.jpg", windowID];
    NSString *command = [NSString stringWithFormat:@"/usr/sbin/screencapture -l %u -t jpg '%@'", windowID, tempFile];
    
    int result = system([command UTF8String]);
    
    if (result != 0) {
        NSLog(@"❌ screencapture command failed for window %u", windowID);
        [self send500Response:client_fd];
        return;
    }
    
    // Read the captured file
    NSData *jpegData = [NSData dataWithContentsOfFile:tempFile];
    
    // Clean up temp file
    [[NSFileManager defaultManager] removeItemAtPath:tempFile error:nil];
    
    if (!jpegData || jpegData.length == 0) {
        NSLog(@"❌ Failed to read screenshot file for window %u", windowID);
        [self send500Response:client_fd];
        return;
    }
    
    // Convert to base64
    NSString *base64String = [jpegData base64EncodedStringWithOptions:0];
    NSString *dataURL = [NSString stringWithFormat:@"data:image/jpeg;base64,%@", base64String];
    
    NSLog(@"✅ Window screenshot captured: %lu bytes", jpegData.length);
    [self sendJSONResponse:client_fd data:@{@"screenshot": dataURL, @"cgWindowID": @(windowID)}];
}

- (void)sendJSONResponse:(int)client_fd data:(NSDictionary *)data {
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:data options:0 error:&error];
    
    NSString *headers = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nAccess-Control-Allow-Origin: *\r\n\r\n", 
                        (unsigned long)jsonData.length];
    
    send(client_fd, [headers UTF8String], headers.length, 0);
    send(client_fd, jsonData.bytes, jsonData.length, 0);
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

- (void)sendCORSResponse:(int)client_fd {
    NSString *response = @"HTTP/1.1 200 OK\r\n"
                         @"Access-Control-Allow-Origin: *\r\n"
                         @"Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
                         @"Access-Control-Allow-Headers: Content-Type\r\n"
                         @"Content-Length: 0\r\n\r\n";
    send(client_fd, [response UTF8String], response.length, 0);
}

- (void)sendWebUIResponse:(int)client_fd {
    NSString *html = @"<!DOCTYPE html>\n"
                     @"<html>\n"
                     @"<head>\n"
                     @"    <title>Remote Desktop</title>\n"
                     @"    <meta charset=\"utf-8\">\n"
                     @"    <style>\n"
                     @"        body { margin: 0; padding: 20px; font-family: Arial, sans-serif; background: #1a1a1a; color: white; }\n"
                     @"        .controls { margin-bottom: 20px; display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }\n"
                     @"        button { padding: 8px 16px; background: #333; color: white; border: 1px solid #555; border-radius: 4px; cursor: pointer; }\n"
                     @"        button:hover { background: #444; }\n"
                     @"        button.active { background: #0066cc; }\n"
                     @"        select { padding: 8px; background: #333; color: white; border: 1px solid #555; border-radius: 4px; }\n"
                     @"        .status { padding: 10px; background: #333; border-radius: 4px; margin-bottom: 10px; }\n"
                     @"        .screen-container { position: relative; border: 1px solid #555; background: #000; }\n"
                     @"        .screen { max-width: 100%; height: auto; display: block; cursor: crosshair; }\n"
                     @"        .loading { text-align: center; padding: 50px; color: #888; }\n"
                     @"    </style>\n"
                     @"</head>\n"
                     @"<body>\n"
                     @"    <h1>Remote Desktop Control</h1>\n"
                     @"    \n"
                     @"    <div class=\"controls\">\n"
                     @"        <button id=\"start-btn\" onclick=\"startCapture()\">Start Desktop Capture</button>\n"
                     @"        <label>Quality:</label>\n"
                     @"        <button id=\"standard-btn\" class=\"active\" onclick=\"setQuality(false)\">Standard</button>\n"
                     @"        <button id=\"hq-btn\" onclick=\"setQuality(true)\">High Quality</button>\n"
                     @"        <select id=\"window-select\" onchange=\"switchToWindow()\">\n"
                     @"            <option value=\"0\">Full Desktop</option>\n"
                     @"        </select>\n"
                     @"        <button onclick=\"refreshWindows()\">Refresh Windows</button>\n"
                     @"    </div>\n"
                     @"    \n"
                     @"    <div class=\"status\" id=\"status\">Ready to start capture</div>\n"
                     @"    \n"
                     @"    <div class=\"screen-container\">\n"
                     @"        <img id=\"screen\" class=\"screen\" onclick=\"handleClick(event)\" onload=\"onFrameLoad()\" style=\"display: none;\">\n"
                     @"        <div id=\"loading\" class=\"loading\">Click 'Start Desktop Capture' to begin</div>\n"
                     @"    </div>\n"
                     @"    \n"
                     @"    <script>\n"
                     @"        let isCapturing = false;\n"
                     @"        let pollInterval = null;\n"
                     @"        let isHQMode = false;\n"
                     @"        let currentWindowId = 0;\n"
                     @"        let windows = [];\n"
                     @"        \n"
                     @"        function setStatus(msg) {\n"
                     @"            document.getElementById('status').textContent = msg;\n"
                     @"        }\n"
                     @"        \n"
                     @"        function setQuality(hq) {\n"
                     @"            isHQMode = hq;\n"
                     @"            document.getElementById('standard-btn').className = hq ? '' : 'active';\n"
                     @"            document.getElementById('hq-btn').className = hq ? 'active' : '';\n"
                     @"            if (isCapturing) {\n"
                     @"                startCapture();\n"
                     @"            }\n"
                     @"        }\n"
                     @"        \n"
                     @"        async function startCapture() {\n"
                     @"            try {\n"
                     @"                setStatus('Starting capture...');\n"
                     @"                \n"
                     @"                let response;\n"
                     @"                if (currentWindowId === 0) {\n"
                     @"                    // Desktop capture\n"
                     @"                    response = await fetch('/capture', {\n"
                     @"                        method: 'POST',\n"
                     @"                        headers: { 'Content-Type': 'application/json' },\n"
                     @"                        body: JSON.stringify({\n"
                     @"                            type: 0,\n"
                     @"                            index: 0,\n"
                     @"                            vp9: isHQMode\n"
                     @"                        })\n"
                     @"                    });\n"
                     @"                } else {\n"
                     @"                    // Window capture\n"
                     @"                    response = await fetch('/capture-window', {\n"
                     @"                        method: 'POST',\n"
                     @"                        headers: { 'Content-Type': 'application/json' },\n"
                     @"                        body: JSON.stringify({\n"
                     @"                            cgWindowID: getCGWindowID(currentWindowId),\n"
                     @"                            vp9: isHQMode\n"
                     @"                        })\n"
                     @"                    });\n"
                     @"                }\n"
                     @"                \n"
                     @"                if (response.ok) {\n"
                     @"                    isCapturing = true;\n"
                     @"                    document.getElementById('start-btn').textContent = 'Stop Capture';\n"
                     @"                    document.getElementById('start-btn').onclick = stopCapture;\n"
                     @"                    document.getElementById('loading').style.display = 'none';\n"
                     @"                    document.getElementById('screen').style.display = 'block';\n"
                     @"                    startPolling();\n"
                     @"                    setStatus('Capture active - ' + (isHQMode ? 'High Quality' : 'Standard') + ' mode');\n"
                     @"                } else {\n"
                     @"                    setStatus('Failed to start capture');\n"
                     @"                }\n"
                     @"            } catch (e) {\n"
                     @"                setStatus('Error: ' + e.message);\n"
                     @"            }\n"
                     @"        }\n"
                     @"        \n"
                     @"        function stopCapture() {\n"
                     @"            isCapturing = false;\n"
                     @"            if (pollInterval) {\n"
                     @"                clearInterval(pollInterval);\n"
                     @"                pollInterval = null;\n"
                     @"            }\n"
                     @"            document.getElementById('start-btn').textContent = 'Start Desktop Capture';\n"
                     @"            document.getElementById('start-btn').onclick = startCapture;\n"
                     @"            document.getElementById('screen').style.display = 'none';\n"
                     @"            document.getElementById('loading').style.display = 'block';\n"
                     @"            setStatus('Capture stopped');\n"
                     @"        }\n"
                     @"        \n"
                     @"        function startPolling() {\n"
                     @"            if (pollInterval) clearInterval(pollInterval);\n"
                     @"            \n"
                     @"            pollInterval = setInterval(async () => {\n"
                     @"                if (!isCapturing) return;\n"
                     @"                \n"
                     @"                try {\n"
                     @"                    const response = await fetch('/frame?' + Date.now());\n"
                     @"                    if (response.ok) {\n"
                     @"                        const frameBlob = await response.blob();\n"
                     @"                        const imageUrl = URL.createObjectURL(frameBlob);\n"
                     @"                        const oldUrl = document.getElementById('screen').src;\n"
                     @"                        document.getElementById('screen').src = imageUrl;\n"
                     @"                        if (oldUrl && oldUrl.startsWith('blob:')) {\n"
                     @"                            URL.revokeObjectURL(oldUrl);\n"
                     @"                        }\n"
                     @"                    }\n"
                     @"                } catch (e) {\n"
                     @"                    console.error('Frame fetch error:', e);\n"
                     @"                    setStatus('Connection error - retrying...');\n"
                     @"                }\n"
                     @"            }, 200);\n"
                     @"        }\n"
                     @"        \n"
                     @"        function onFrameLoad() {\n"
                     @"            if (isCapturing) {\n"
                     @"                setStatus('Capture active - ' + (isHQMode ? 'High Quality' : 'Standard') + ' mode');\n"
                     @"            }\n"
                     @"        }\n"
                     @"        \n"
                     @"        async function handleClick(event) {\n"
                     @"            const rect = event.target.getBoundingClientRect();\n"
                     @"            const scaleX = event.target.naturalWidth / rect.width;\n"
                     @"            const scaleY = event.target.naturalHeight / rect.height;\n"
                     @"            const x = Math.round((event.clientX - rect.left) * scaleX);\n"
                     @"            const y = Math.round((event.clientY - rect.top) * scaleY);\n"
                     @"            \n"
                     @"            try {\n"
                     @"                const endpoint = currentWindowId === 0 ? '/click' : '/click-window';\n"
                     @"                const body = currentWindowId === 0 ? \n"
                     @"                    { x: x, y: y } : \n"
                     @"                    { x: x, y: y, cgWindowID: getCGWindowID(currentWindowId) };\n"
                     @"                \n"
                     @"                await fetch(endpoint, {\n"
                     @"                    method: 'POST',\n"
                     @"                    headers: { 'Content-Type': 'application/json' },\n"
                     @"                    body: JSON.stringify(body)\n"
                     @"                });\n"
                     @"                \n"
                     @"                setStatus('Clicked at (' + x + ', ' + y + ')');\n"
                     @"            } catch (e) {\n"
                     @"                setStatus('Click error: ' + e.message);\n"
                     @"            }\n"
                     @"        }\n"
                     @"        \n"
                     @"        document.addEventListener('keydown', async (event) => {\n"
                     @"            if (event.target.tagName === 'INPUT' || event.target.tagName === 'SELECT') return;\n"
                     @"            if (!isCapturing) return;\n"
                     @"            \n"
                     @"            event.preventDefault();\n"
                     @"            \n"
                     @"            try {\n"
                     @"                const endpoint = currentWindowId === 0 ? '/key' : '/key-window';\n"
                     @"                const body = currentWindowId === 0 ? \n"
                     @"                    { key: event.key } : \n"
                     @"                    { key: event.key, cgWindowID: getCGWindowID(currentWindowId) };\n"
                     @"                \n"
                     @"                await fetch(endpoint, {\n"
                     @"                    method: 'POST',\n"
                     @"                    headers: { 'Content-Type': 'application/json' },\n"
                     @"                    body: JSON.stringify(body)\n"
                     @"                });\n"
                     @"            } catch (e) {\n"
                     @"                console.error('Key error:', e);\n"
                     @"            }\n"
                     @"        });\n"
                     @"        \n"
                     @"        async function refreshWindows() {\n"
                     @"            try {\n"
                     @"                const response = await fetch('/windows');\n"
                     @"                if (response.ok) {\n"
                     @"                    windows = await response.json();\n"
                     @"                    updateWindowSelect();\n"
                     @"                    setStatus('Windows refreshed');\n"
                     @"                }\n"
                     @"            } catch (e) {\n"
                     @"                setStatus('Error refreshing windows: ' + e.message);\n"
                     @"            }\n"
                     @"        }\n"
                     @"        \n"
                     @"        function updateWindowSelect() {\n"
                     @"            const select = document.getElementById('window-select');\n"
                     @"            select.innerHTML = '<option value=\"0\">Full Desktop</option>';\n"
                     @"            \n"
                     @"            windows.forEach(window => {\n"
                     @"                const option = document.createElement('option');\n"
                     @"                option.value = window.id;\n"
                     @"                option.textContent = window.app + ' - ' + window.title;\n"
                     @"                select.appendChild(option);\n"
                     @"            });\n"
                     @"        }\n"
                     @"        \n"
                     @"        function switchToWindow() {\n"
                     @"            const select = document.getElementById('window-select');\n"
                     @"            currentWindowId = parseInt(select.value);\n"
                     @"            \n"
                     @"            if (isCapturing) {\n"
                     @"                startCapture();\n"
                     @"            }\n"
                     @"        }\n"
                     @"        \n"
                     @"        function getCGWindowID(windowId) {\n"
                     @"            if (windowId === 0) return 0;\n"
                     @"            const window = windows.find(w => w.id === windowId);\n"
                     @"            return window ? window.cgWindowID : 0;\n"
                     @"        }\n"
                     @"        \n"
                     @"        // Initialize\n"
                     @"        refreshWindows();\n"
                     @"    </script>\n"
                     @"</body>\n"
                     @"</html>";
    
    NSData *htmlData = [html dataUsingEncoding:NSUTF8StringEncoding];
    NSString *headers = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: %lu\r\n\r\n", 
                        (unsigned long)htmlData.length];
    
    send(client_fd, [headers UTF8String], headers.length, 0);
    send(client_fd, htmlData.bytes, htmlData.length, 0);
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