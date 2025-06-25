#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

@protocol ClickableViewDelegate <NSObject>
- (void)clickableView:(NSView *)view didClickAtPoint:(NSPoint)point;
@end

@interface ClickableView : NSView
@property (nonatomic, assign) id<ClickableViewDelegate> delegate;
@end

@implementation ClickableView

- (void)mouseDown:(NSEvent *)event {
    NSLog(@"CLICK-CALIBRATE: 🔍 mouseDown detected in ClickableView");
    NSPoint locationInWindow = [event locationInWindow];
    NSPoint locationInView = [self convertPoint:locationInWindow fromView:nil];
    NSPoint mouseLocation = [NSEvent mouseLocation]; // Global screen coordinates
    
    NSLog(@"CLICK-CALIBRATE: 🎯 Raw event location: (%.0f, %.0f)", locationInWindow.x, locationInWindow.y);
    NSLog(@"CLICK-CALIBRATE: 🎯 View coordinates: (%.0f, %.0f)", locationInView.x, locationInView.y);
    NSLog(@"CLICK-CALIBRATE: 🎯 Mouse screen location: (%.0f, %.0f)", mouseLocation.x, mouseLocation.y);
    
    if (self.delegate) {
        [self.delegate clickableView:self didClickAtPoint:locationInView];
    }
}

@end

@interface ClickTracker : NSObject <ClickableViewDelegate>
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
    
    // Set up click tracking for fullscreen
    [contentView setAcceptsTouchEvents:YES];
    
    // Override mouse events directly instead of gesture recognizer
    // Create a custom view that captures mouse events
    ClickableView *clickView = [[ClickableView alloc] initWithFrame:screenFrame];
    clickView.delegate = self;
    [self.window setContentView:clickView];
    
    // Re-add all UI elements to the new clickable view
    [clickView addSubview:titleLabel];
    [clickView addSubview:self.statusLabel];
    [clickView addSubview:self.coordsLabel];
    [clickView addSubview:instructions];
    [clickView addSubview:self.connectButton];
    [clickView addSubview:windowInfo];
    [clickView addSubview:exitLabel];
    
    // Add ESC key handler
    [self.window setAcceptsMouseMovedEvents:YES];
    [self.window makeKeyAndOrderFront:nil];
}

// Handle key events for ESC to exit
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 53) { // ESC key
        [NSApp terminate:self];
    } else {
        [super keyDown:event];
    }
}

- (void)clickableView:(NSView *)view didClickAtPoint:(NSPoint)locationInView {
    NSLog(@"CLICK-CALIBRATE: 🎯 Processing click from delegate...");
    NSPoint locationInWindow = [view convertPoint:locationInView toView:nil];
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
        
        // Add red dot at click location
        [self drawRedDotAt:locationInView];
        
        // Send to server
        NSLog(@"CLICK-CALIBRATE: 📤 About to send click data to server...");
        [self sendClickToServer:locationInView 
                 windowLocation:locationInWindow 
                 screenLocation:locationOnScreen 
                       windowID:windowID
                    windowFrame:windowFrame];
        
        NSLog(@"CLICK-CALIBRATE: 🖱️ NATIVE CLICK: View(%.0f,%.0f) Window(%.0f,%.0f) Screen(%.0f,%.0f) WindowID:%d", 
              locationInView.x, locationInView.y,
              locationInWindow.x, locationInWindow.y,
              locationOnScreen.x, locationOnScreen.y, (int)windowID);
}

- (void)sendClickToServer:(NSPoint)viewCoords windowLocation:(NSPoint)windowCoords screenLocation:(NSPoint)screenCoords windowID:(CGWindowID)windowID windowFrame:(NSRect)windowFrame {
    NSLog(@"CLICK-CALIBRATE: 🚀 sendClickToServer called - connected: %@, URL: %@", 
          self.isConnected ? @"YES" : @"NO", self.serverURL);
    
    if (!self.isConnected) {
        NSLog(@"CLICK-CALIBRATE: ❌ Not connected to server, skipping click report");
        return;
    }
    
    if (!self.serverURL) {
        NSLog(@"CLICK-CALIBRATE: ❌ Server URL is nil, cannot send click data");
        return;
    }
    
    // Create payload with comprehensive coordinate data
    NSLog(@"CLICK-CALIBRATE: 📝 Creating JSON payload...");
    
    // Convert native coordinates to web client compatible format
    // Use the same logical coordinate system as web client
    CGFloat logicalX = viewCoords.x;
    CGFloat logicalY = viewCoords.y;
    
    // Convert to web client format to match coordinate system
    NSDictionary *payload = @{
        @"event": @"click_tracking",
        @"source": @"ClickTracker_App",
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
        @"coordinates": @{
            @"client": @{@"x": @(logicalX), @"y": @(logicalY)},
            @"element": @"ClickTracker_Native",
            @"viewport": @{@"width": @(windowFrame.size.width), @"height": @(windowFrame.size.height)}
        },
        @"window_info": @{
            @"cgWindowID": @(windowID),
            @"capture_mode": @"fullscreen",
            @"frame": @{
                @"x": @(windowFrame.origin.x),
                @"y": @(windowFrame.origin.y),
                @"width": @(windowFrame.size.width),
                @"height": @(windowFrame.size.height)
            }
        }
    };
    
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    if (error || !jsonData) {
        NSLog(@"CLICK-CALIBRATE: ❌ JSON serialization error: %@", error ? error.localizedDescription : @"Unknown error");
        return;
    }
    
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    NSLog(@"CLICK-CALIBRATE: 📄 JSON payload (%lu bytes): %@", (unsigned long)jsonData.length, jsonString);
    
    // Use raw socket connection instead of NSURLSession
    [self sendRawHTTPRequest:jsonString];
}

- (void)sendRawHTTPRequest:(NSString *)jsonPayload {
    NSLog(@"CLICK-CALIBRATE: 🔌 Creating raw socket connection to localhost:3030");
    
    int sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) {
        NSLog(@"CLICK-CALIBRATE: ❌ Failed to create socket");
        return;
    }
    
    struct sockaddr_in server_addr;
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons(3030);
    server_addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    
    if (connect(sockfd, (struct sockaddr*)&server_addr, sizeof(server_addr)) < 0) {
        NSLog(@"CLICK-CALIBRATE: ❌ Failed to connect to server");
        close(sockfd);
        return;
    }
    
    // Build HTTP request manually
    NSString *httpRequest = [NSString stringWithFormat:
        @"POST /track-click HTTP/1.1\r\n"
        @"Host: localhost:3030\r\n"
        @"Content-Type: application/json\r\n"
        @"Content-Length: %lu\r\n"
        @"\r\n"
        @"%@",
        (unsigned long)[jsonPayload lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
        jsonPayload
    ];
    
    NSLog(@"CLICK-CALIBRATE: 📤 Sending raw HTTP request:\n%@", httpRequest);
    
    const char *requestCString = [httpRequest UTF8String];
    ssize_t bytesSent = send(sockfd, requestCString, strlen(requestCString), 0);
    
    NSLog(@"CLICK-CALIBRATE: 📊 Sent %zd bytes to server", bytesSent);
    
    // Read response
    char response[1024];
    ssize_t bytesReceived = recv(sockfd, response, sizeof(response) - 1, 0);
    if (bytesReceived > 0) {
        response[bytesReceived] = '\0';
        NSLog(@"CLICK-CALIBRATE: 📥 Server response: %s", response);
    }
    
    close(sockfd);
    NSLog(@"CLICK-CALIBRATE: ✅ Raw socket connection closed");
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

- (void)drawRedDotAt:(NSPoint)location {
    // Remove any existing red dots
    NSView *contentView = [self.window contentView];
    NSArray *subviews = [contentView subviews];
    for (NSView *view in subviews) {
        if ([view.identifier isEqualToString:@"redDot"]) {
            [view removeFromSuperview];
        }
    }
    
    // Create new red dot at click location
    NSView *redDot = [[NSView alloc] initWithFrame:NSMakeRect(location.x - 5, location.y - 5, 10, 10)];
    [redDot setWantsLayer:YES];
    redDot.layer.backgroundColor = [NSColor redColor].CGColor;
    redDot.layer.cornerRadius = 5.0;
    redDot.identifier = @"redDot";
    
    [contentView addSubview:redDot];
    
    // Remove the dot after 3 seconds
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [redDot removeFromSuperview];
    });
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