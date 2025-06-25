# Coordinate Testing Setup

This setup provides a comprehensive way to test mouse coordinate accuracy across different systems:

## Components

### 1. ClickTracker.app (Native macOS App)
- **Size**: 500x500px window
- **Purpose**: Records native mouse clicks and sends data to screencap7 server
- **Coordinates**: Provides view, window, and screen coordinates
- **CGWindowID**: Shows the window ID for testing window-specific capture

### 2. screencap7 Server (Updated)
- **New Endpoint**: `/track-click` - receives click tracking data
- **Modes**: Full desktop capture vs window capture
- **Coordinate Transformation**: Automatic calibration for Retina displays
- **Logging**: Comprehensive click coordinate logging

### 3. Web Client (Embedded UI)
- **Enhanced**: Now sends click tracking data to `/track-click`
- **Data**: Client coordinates, viewport info, capture mode
- **Real-time**: Shows coordinate feedback in browser

## Usage Instructions

### Step 1: Start the Server
```bash
cd /Users/hjanuschka/node-sharer
killall screencap7 
make run
```

### Step 2: Launch ClickTracker App
```bash
# In a new terminal
cd /Users/hjanuschka/node-sharer
clang -o ClickTracker ClickTracker.m -framework Cocoa -framework Foundation
./ClickTracker
```

### Step 3: Test Full Desktop Mode
1. Open web browser to `http://localhost:3030`
2. Click "Start Desktop Capture" (full screen mode)
3. Click anywhere on the ClickTracker app window
4. Observe logs in `server.log`

### Step 4: Test Window Capture Mode
1. In web browser, select "ClickTracker" from window dropdown
2. Click "Start Capture" (window mode)
3. Click anywhere in the ClickTracker app window
4. Observe logs in `server.log`

## Expected Log Output

When you click in the ClickTracker app, you should see:

```bash
# From ClickTracker app (Console.app or terminal)
🖱️ LOCAL CLICK: View(250.0,300.0) Window(250.0,300.0) Screen(350.0,400.0) WindowID:12345

# From screencap7 server (server.log)
🎯 CLICK TRACKING from ClickTracker_App:
   📍 View: (250.0, 300.0)
   🪟 Window: (250.0, 300.0)  
   🖥️ Screen: (350.0, 400.0)
   📏 Window Frame: (100,100) 500x500
   🆔 CGWindowID: 12345
   ⏰ Timestamp: 1735142234.567

🎯 CLICK TRACKING from Web_Client:
   📍 Client: (250.0, 300.0)
   🖥️ Element: IMG
   📏 Viewport: 1920x1080
   🆔 CGWindowID: 12345
   🎯 Mode: window

# Server coordinate processing (when clicking through web)
🔄 Coordinate transform: (250.0, 300.0) → (250.0, 325.0)  # Added window title bar offset
```

## Testing Scenarios

### 1. Full Screen Capture
- **Expected**: 2x scaling for Retina displays
- **Log**: `Mode=0, scaleX=2.000, scaleY=2.000`

### 2. Window Capture  
- **Expected**: 1x scaling + window offset
- **Log**: `Mode=2, scaleX=1.000, scaleY=1.000, offsetY=25.0`

### 3. Coordinate Accuracy
- Compare coordinates from:
  - Native app (true window coordinates)
  - Web client (browser coordinates) 
  - Server processing (transformed coordinates)

## Files
- `ClickTracker.m` - Native macOS tracking app
- `screencap7_clean.m` - Updated server with `/track-click` endpoint
- `server.log` - Contains all coordinate tracking logs