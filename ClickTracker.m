#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>

@interface ClickTracker : NSObject
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSTextField *coordsLabel;
@property (nonatomic, strong) NSButton *connectButton;
@property (nonatomic, assign) BOOL isConnected;
@property (nonatomic, strong) NSString *serverURL;
@end

@implementation ClickTracker

- (instancetype)init {
    self = [super init];
    if (self) {
        self.serverURL = @"http://localhost:3030";
        self.isConnected = NO;
        [self createWindow];
        [self testServerConnection];
    }
    return self;
}

- (void)createWindow {
    // Create fullscreen window for accurate coordinate testing
    NSScreen *mainScreen = [NSScreen mainScreen];
    NSRect screenFrame = [mainScreen frame];
    self.window = [[NSWindow alloc] initWithContentRect:screenFrame
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    
    [self.window setTitle:@"Click Tracker - Fullscreen"];
    [self.window setReleasedWhenClosed:NO];
    [self.window setLevel:NSFloatingWindowLevel]; // Keep on top
    [self.window setBackgroundColor:[NSColor blackColor]];
    
    // Create content view
    NSView *contentView = [[NSView alloc] initWithFrame:screenFrame];
    [self.window setContentView:contentView];
    
    // Calculate centered positions for fullscreen
    CGFloat screenWidth = screenFrame.size.width;
    CGFloat screenHeight = screenFrame.size.height;
    CGFloat centerX = screenWidth / 2;
    
    // Title label - centered at top
    NSTextField *titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(centerX - 300, screenHeight - 100, 600, 40)];
    [titleLabel setStringValue:@"CLICK TRACKER - FULLSCREEN COORDINATE TESTING"];
    [titleLabel setBezeled:NO];
    [titleLabel setDrawsBackground:NO];
    [titleLabel setEditable:NO];
    [titleLabel setSelectable:NO];
    [titleLabel setAlignment:NSTextAlignmentCenter];
    [titleLabel setFont:[NSFont boldSystemFontOfSize:24]];
    [titleLabel setTextColor:[NSColor whiteColor]];
    [contentView addSubview:titleLabel];
    
    // Status label - centered
    self.statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(centerX - 300, screenHeight - 150, 600, 30)];
    [self.statusLabel setStringValue:@"Connecting to server..."];
    [self.statusLabel setBezeled:NO];
    [self.statusLabel setDrawsBackground:NO];
    [self.statusLabel setEditable:NO];
    [self.statusLabel setSelectable:NO];
    [self.statusLabel setAlignment:NSTextAlignmentCenter];
    [self.statusLabel setFont:[NSFont systemFontOfSize:18]];
    [self.statusLabel setTextColor:[NSColor yellowColor]];
    [contentView addSubview:self.statusLabel];
    
    // Coordinates label - centered
    self.coordsLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(centerX - 400, screenHeight/2 + 100, 800, 30)];
    [self.coordsLabel setStringValue:@"Click anywhere on this fullscreen window to test coordinates"];
    [self.coordsLabel setBezeled:NO];
    [self.coordsLabel setDrawsBackground:NO];
    [self.coordsLabel setEditable:NO];
    [self.coordsLabel setSelectable:NO];
    [self.coordsLabel setAlignment:NSTextAlignmentCenter];
    [self.coordsLabel setFont:[NSFont systemFontOfSize:16]];
    [self.coordsLabel setTextColor:[NSColor cyanColor]];
    [contentView addSubview:self.coordsLabel];
    
    // Instructions - centered
    NSTextField *instructions = [[NSTextField alloc] initWithFrame:NSMakeRect(centerX - 400, screenHeight/2, 800, 80)];
    [instructions setStringValue:@"FULLSCREEN COORDINATE TESTING:\n• Click anywhere to track coordinates\n• Data sent to screencap7 server\n• Press ESC to exit fullscreen"];
    [instructions setBezeled:NO];
    [instructions setDrawsBackground:NO];
    [instructions setEditable:NO];
    [instructions setSelectable:NO];
    [instructions setAlignment:NSTextAlignmentCenter];
    [instructions setFont:[NSFont systemFontOfSize:16]];
    [instructions setTextColor:[NSColor lightGrayColor]];
    [contentView addSubview:instructions];
    
    // Connect button - centered
    self.connectButton = [[NSButton alloc] initWithFrame:NSMakeRect(centerX - 50, screenHeight/2 - 100, 100, 40)];
    [self.connectButton setTitle:@"Reconnect"];
    [self.connectButton setTarget:self];
    [self.connectButton setAction:@selector(reconnectToServer:)];
    [self.connectButton setFont:[NSFont systemFontOfSize:16]];
    [contentView addSubview:self.connectButton];
    
    // Window info - centered at bottom
    CGWindowID windowID = (CGWindowID)[self.window windowNumber];
    NSTextField *windowInfo = [[NSTextField alloc] initWithFrame:NSMakeRect(centerX - 300, 50, 600, 40)];
    [windowInfo setStringValue:[NSString stringWithFormat:@"CGWindowID: %d | Resolution: %.0fx%.0f | Server: %@", 
                               (int)windowID, screenWidth, screenHeight, self.serverURL]];
    [windowInfo setBezeled:NO];
    [windowInfo setDrawsBackground:NO];
    [windowInfo setEditable:NO];
    [windowInfo setSelectable:NO];
    [windowInfo setAlignment:NSTextAlignmentCenter];
    [windowInfo setFont:[NSFont systemFontOfSize:14]];
    [windowInfo setTextColor:[NSColor darkGrayColor]];
    [contentView addSubview:windowInfo];
    
    // Set up click tracking for fullscreen
    [contentView setAcceptsTouchEvents:YES];
    
    // Add click gesture recognizer
    NSClickGestureRecognizer *clickGesture = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(handleClick:)];
    [contentView addGestureRecognizer:clickGesture];
    
    // Add ESC key handler
    [self.window setAcceptsMouseMovedEvents:YES];
    [self.window makeKeyAndOrderFront:nil];
    
    // Add exit instructions
    NSTextField *exitLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(centerX - 200, 100, 400, 30)];
    [exitLabel setStringValue:@"Press ESC or Cmd+Q to exit fullscreen"];
    [exitLabel setBezeled:NO];
    [exitLabel setDrawsBackground:NO];
    [exitLabel setEditable:NO];
    [exitLabel setSelectable:NO];
    [exitLabel setAlignment:NSTextAlignmentCenter];
    [exitLabel setFont:[NSFont systemFontOfSize:12]];
    [exitLabel setTextColor:[NSColor redColor]];
    [contentView addSubview:exitLabel];
}

// Handle key events for ESC to exit
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 53) { // ESC key
        [NSApp terminate:self];
    } else {
        [super keyDown:event];
    }
}

- (void)handleClick:(NSClickGestureRecognizer *)gesture {
    if (gesture.state == NSGestureRecognizerStateEnded) {
        NSPoint locationInView = [gesture locationInView:gesture.view];
        NSPoint locationInWindow = [gesture.view convertPoint:locationInView toView:nil];
        NSPoint locationOnScreen = [self.window convertPointToScreen:locationInWindow];
        
        // Get window bounds for context
        NSRect windowFrame = [self.window frame];
        CGWindowID windowID = (CGWindowID)[self.window windowNumber];
        
        // Display coordinates in the app
        NSString *coordsText = [NSString stringWithFormat:@"Click: View(%.0f,%.0f) Window(%.0f,%.0f) Screen(%.0f,%.0f)", 
                               locationInView.x, locationInView.y,
                               locationInWindow.x, locationInWindow.y,
                               locationOnScreen.x, locationOnScreen.y];
        [self.coordsLabel setStringValue:coordsText];
        
        // Send to server
        [self sendClickToServer:locationInView 
                 windowLocation:locationInWindow 
                 screenLocation:locationOnScreen 
                       windowID:windowID
                    windowFrame:windowFrame];
        
        NSLog(@"CLICK-CALIBRATE: 🖱️ LOCAL CLICK: View(%.0f,%.0f) Window(%.0f,%.0f) Screen(%.0f,%.0f) WindowID:%d", 
              locationInView.x, locationInView.y,
              locationInWindow.x, locationInWindow.y,
              locationOnScreen.x, locationOnScreen.y, (int)windowID);
    }
}

- (void)sendClickToServer:(NSPoint)viewCoords windowLocation:(NSPoint)windowCoords screenLocation:(NSPoint)screenCoords windowID:(CGWindowID)windowID windowFrame:(NSRect)windowFrame {
    if (!self.isConnected) {
        NSLog(@"❌ Not connected to server, skipping click report");
        return;
    }
    
    if (!self.serverURL) {
        NSLog(@"❌ Server URL is nil, cannot send click data");
        return;
    }
    
    // Create payload with comprehensive coordinate data
    NSDictionary *payload = @{
        @"event": @"click_tracking",
        @"source": @"ClickTracker_App",
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
        @"coordinates": @{
            @"view": @{@"x": @(viewCoords.x), @"y": @(viewCoords.y)},
            @"window": @{@"x": @(windowCoords.x), @"y": @(windowCoords.y)},
            @"screen": @{@"x": @(screenCoords.x), @"y": @(screenCoords.y)}
        },
        @"window_info": @{
            @"cgWindowID": @(windowID),
            @"frame": @{
                @"x": @(windowFrame.origin.x),
                @"y": @(windowFrame.origin.y),
                @"width": @(windowFrame.size.width),
                @"height": @(windowFrame.size.height)
            }
        }
    };
    
    // Send via HTTP POST
    NSString *urlString = [NSString stringWithFormat:@"%@/track-click", self.serverURL];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        NSLog(@"❌ Invalid URL: %@", urlString);
        return;
    }
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    if (!request) {
        NSLog(@"❌ Failed to create URL request");
        return;
    }
    
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    if (error || !jsonData) {
        NSLog(@"❌ JSON serialization error: %@", error ? error.localizedDescription : @"Unknown error");
        return;
    }
    
    [request setHTTPBody:jsonData];
    
    NSURLSession *session = [NSURLSession sharedSession];
    if (!session) {
        NSLog(@"❌ Failed to get URL session");
        return;
    }
    
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
        if (taskError) {
            NSLog(@"❌ Failed to send click to server: %@", taskError.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self && self.statusLabel) {
                    self.isConnected = NO;
                    [self.statusLabel setStringValue:@"❌ Server connection lost"];
                }
            });
        } else {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            if (httpResponse && httpResponse.statusCode == 200) {
                NSLog(@"✅ Click data sent to server successfully");
            } else {
                NSLog(@"⚠️ Server responded with status: %ld", httpResponse ? (long)httpResponse.statusCode : -1);
            }
        }
    }];
    
    if (task) {
        [task resume];
    } else {
        NSLog(@"❌ Failed to create data task");
    }
}

- (void)testServerConnection {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/display", self.serverURL]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"GET"];
    [request setTimeoutInterval:5.0];
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                self.isConnected = NO;
                [self.statusLabel setStringValue:@"❌ Server not reachable"];
                NSLog(@"❌ Server connection failed: %@", error.localizedDescription);
            } else {
                NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
                if (httpResponse.statusCode == 200) {
                    self.isConnected = YES;
                    [self.statusLabel setStringValue:@"✅ Connected to screencap7 server"];
                    NSLog(@"✅ Connected to server successfully");
                } else {
                    self.isConnected = NO;
                    [self.statusLabel setStringValue:[NSString stringWithFormat:@"❌ Server error: %ld", (long)httpResponse.statusCode]];
                }
            }
        });
    }];
    
    [task resume];
}

- (void)reconnectToServer:(id)sender {
    [self.statusLabel setStringValue:@"Connecting..."];
    [self testServerConnection];
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        
        ClickTracker *tracker = [[ClickTracker alloc] init];
        
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp activateIgnoringOtherApps:YES];
        
        NSLog(@"🚀 ClickTracker app started - connecting to screencap7 server");
        
        [NSApp run];
    }
    return 0;
}