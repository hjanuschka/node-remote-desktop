# Coordinate System Fix Documentation

## Problem Summary

The screen capture system had two main coordinate issues:

1. **Desktop capture**: Small X/Y offset when clicking
2. **Window capture**: Extreme offset due to Retina display scaling

## Root Causes

### Desktop Capture
- ScreenCaptureKit captures at physical resolution (e.g., 3840x2160 on Retina)
- Mouse events use logical coordinates (e.g., 1920x1080)
- The mismatch caused clicks to be offset

### Window Capture
- Windows are captured at 2x resolution on Retina displays
- A 500x500 window is captured as 1000x1000 pixels
- Frontend was sending physical pixel coordinates instead of logical coordinates

## Solution Implemented

### 1. Scale Factor Detection
The system now properly detects and uses the display scale factor:
```javascript
const displayInfo = await getDisplayInfo();
const scaleFactor = displayInfo.scaleFactor || 2;
```

### 2. Desktop Capture Scaling
For full desktop capture, coordinates are scaled down from physical to logical:
```javascript
if (canvasWidth === displayInfo.physicalWidth) {
  scaledX = Math.round(x / scaleFactor);
  scaledY = Math.round(y / scaleFactor);
}
```

### 3. Window Capture Scaling
For window captures on Retina displays:
```javascript
if (isRetinaCapture) {
  scaledX = Math.round(x / scaleFactor);
  scaledY = Math.round(y / scaleFactor);
}
```

## Testing the Fix

### 1. Enable Debug Mode
```bash
DEBUG_COORDS=true node server.js
```

### 2. Run Test Script
```bash
./test-coordinates.sh
```

### 3. Manual Testing
- Visit http://localhost:3030/coordtest for coordinate test app
- Visit http://localhost:3030/coord-info for current configuration

## Fine-Tuning

If clicks are still slightly off, adjust the calibration offsets in `server.js`:

```javascript
const CLICK_OFFSET_X = 0;  // Positive = click more to the right
const CLICK_OFFSET_Y = 0;  // Positive = click more down
```

Common adjustments:
- If clicks are too far left: increase CLICK_OFFSET_X
- If clicks are too high: increase CLICK_OFFSET_Y
- Typical values range from -10 to +10

## Debugging

### Check Logs
The server logs detailed coordinate transformations:
```
Desktop capture scaling: 3840,2160 -> 1920,1080 (scale: 2x)
Window capture Retina scaling: 1000,1000 -> 500,500 (scale: 2x)
```

### Visual Debugging
With DEBUG_COORDS=true, clicks show:
- Red dot at click location
- Coordinate text overlay
- Detailed console output

## Platform Notes

- **macOS**: Uses logical coordinates for mouse events
- **Retina displays**: 2x scaling is common (some have 3x)
- **External monitors**: May have 1x scaling even on Retina Macs

## Future Improvements

1. Auto-detect scale factor per display
2. Handle multiple displays with different scale factors
3. Add per-window scale factor detection
4. Implement coordinate test overlay in capture stream