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
    // Create window
    NSRect windowFrame = NSMakeRect(100, 100, 500, 500);
    self.window = [[NSWindow alloc] initWithContentRect:windowFrame
                                              styleMask:(NSWindowStyleMaskTitled | 
                                                       NSWindowStyleMaskClosable | 
                                                       NSWindowStyleMaskMiniaturizable)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    
    [self.window setTitle:@"Click Tracker"];
    [self.window setReleasedWhenClosed:NO];
    
    // Create content view
    NSView *contentView = [[NSView alloc] initWithFrame:windowFrame];
    [self.window setContentView:contentView];
    
    // Title label
    NSTextField *titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 450, 460, 30)];
    [titleLabel setStringValue:@"Click Tracker - Coordinate Testing"];
    [titleLabel setBezeled:NO];
    [titleLabel setDrawsBackground:NO];
    [titleLabel setEditable:NO];
    [titleLabel setSelectable:NO];
    [titleLabel setFont:[NSFont boldSystemFontOfSize:16]];
    [contentView addSubview:titleLabel];
    
    // Status label
    self.statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 420, 460, 20)];
    [self.statusLabel setStringValue:@"Connecting to server..."];
    [self.statusLabel setBezeled:NO];
    [self.statusLabel setDrawsBackground:NO];
    [self.statusLabel setEditable:NO];
    [self.statusLabel setSelectable:NO];
    [contentView addSubview:self.statusLabel];
    
    // Coordinates label
    self.coordsLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 390, 460, 20)];
    [self.coordsLabel setStringValue:@"Click anywhere in this window to test coordinates"];
    [self.coordsLabel setBezeled:NO];
    [self.coordsLabel setDrawsBackground:NO];
    [self.coordsLabel setEditable:NO];
    [self.coordsLabel setSelectable:NO];
    [contentView addSubview:self.coordsLabel];
    
    // Instructions
    NSTextField *instructions = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 300, 460, 80)];
    [instructions setStringValue:@"This 500x500px window will:\n• Track your clicks in this window\n• Send coordinates to the screencap7 server\n• Log both local and server coordinates\n• Test both full screen and window capture modes"];
    [instructions setBezeled:NO];
    [instructions setDrawsBackground:NO];
    [instructions setEditable:NO];
    [instructions setSelectable:NO];
    [contentView addSubview:instructions];
    
    // Connect button
    self.connectButton = [[NSButton alloc] initWithFrame:NSMakeRect(200, 250, 100, 30)];
    [self.connectButton setTitle:@"Reconnect"];
    [self.connectButton setTarget:self];
    [self.connectButton setAction:@selector(reconnectToServer:)];
    [contentView addSubview:self.connectButton];
    
    // Server URL label
    NSTextField *urlLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 220, 460, 20)];
    [urlLabel setStringValue:[NSString stringWithFormat:@"Server: %@", self.serverURL]];
    [urlLabel setBezeled:NO];
    [urlLabel setDrawsBackground:NO];
    [urlLabel setEditable:NO];
    [urlLabel setSelectable:NO];
    [urlLabel setFont:[NSFont systemFontOfSize:11]];
    [contentView addSubview:urlLabel];
    
    // Window info
    NSTextField *windowInfo = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 190, 460, 20)];
    CGWindowID windowID = (CGWindowID)[self.window windowNumber];
    [windowInfo setStringValue:[NSString stringWithFormat:@"This window's CGWindowID: %d (500x500px)", (int)windowID]];
    [windowInfo setBezeled:NO];
    [windowInfo setDrawsBackground:NO];
    [windowInfo setEditable:NO];
    [windowInfo setSelectable:NO];
    [windowInfo setFont:[NSFont systemFontOfSize:11]];
    [contentView addSubview:windowInfo];
    
    // Large click area visualization
    NSTextField *clickArea = [[NSTextField alloc] initWithFrame:NSMakeRect(50, 50, 400, 120)];
    [clickArea setStringValue:@"LARGE CLICK AREA\n\nClick anywhere in this area to test coordinate accuracy.\nThis will help compare:\n• Client coordinates (from web UI)\n• Server coordinates (screencap7 processing)\n• Native app coordinates (this app)"];
    [clickArea setBezeled:YES];
    [clickArea setDrawsBackground:YES];
    [clickArea setBackgroundColor:[NSColor colorWithWhite:0.95 alpha:1.0]];
    [clickArea setEditable:NO];
    [clickArea setSelectable:NO];
    [clickArea setAlignment:NSTextAlignmentCenter];
    [clickArea setFont:[NSFont systemFontOfSize:14]];
    [contentView addSubview:clickArea];
    
    // Set up click tracking
    [contentView setAcceptsTouchEvents:YES];
    
    // Add click gesture recognizer
    NSClickGestureRecognizer *clickGesture = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(handleClick:)];
    [contentView addGestureRecognizer:clickGesture];
    
    [self.window makeKeyAndOrderFront:nil];
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