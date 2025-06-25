const express = require('express');
const { exec, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { v4: uuidv4 } = require('uuid');
const WebSocket = require('ws');
const cors = require('cors');

// Auto-start FFmpeg screen capture when server starts
const platform = os.platform();
let ffmpegProcess = null;

// Use automatic screencapture instead of broken FFmpeg
let captureInterval = null;

// Track current capture mode and window
let currentCaptureMode = 'desktop'; // 'desktop' or 'window'
let currentWindowID = null;

async function startServerScreenCapture() {
  console.log('🚀 Starting HTTP API screen capture server...');
  
  if (platform === 'darwin') {
    // Auto-recompile native binaries on startup
    const nativeDir = path.join(__dirname, 'native', 'osx');
    console.log('🔨 Recompiling native binaries...');
    
    // Compile main capture binary first
    const compileScreencap = new Promise((resolve, reject) => {
      exec(`cd "${nativeDir}" && clang -o screencap7 screencap7_clean.m vp9_encoder.m -framework Foundation -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework ImageIO -framework UniformTypeIdentifiers -framework CoreGraphics -framework AppKit -framework VideoToolbox -framework QuartzCore`, (error) => {
        if (error) {
          console.error('❌ Failed to compile screencap7:', error.message);
          reject(error);
        } else {
          console.log('✅ screencap7 compiled successfully');
          resolve();
        }
      });
    });
    
    // Compile window listing tool
    const compileListWindows = new Promise((resolve, reject) => {
      exec(`cd "${nativeDir}" && clang -o list_windows_cg list_windows_cg.m -framework Foundation -framework CoreGraphics`, (error) => {
        if (error) {
          console.error('❌ Failed to compile list_windows_cg:', error.message);
          reject(error);
        } else {
          console.log('✅ list_windows_cg compiled successfully');
          resolve();
        }
      });
    });
    
    // Wait for screencap7 compilation before proceeding
    try {
      await compileScreencap;
      // list_windows_cg can compile in parallel, don't wait for it
      compileListWindows.catch(() => {}); // Ignore errors
      
      console.log('🔥 Starting native macOS ScreenCaptureKit HTTP server...');
      startNativeServer();
    } catch (error) {
      console.error('❌ Failed to compile required screencap7 binary');
      return;
    }
  } else {
    console.error('❌ Unsupported platform:', platform);
  }
}

function startNativeServer() {
  const binaryPath = path.join(__dirname, 'native', 'osx', 'screencap7');
  
  if (!fs.existsSync(binaryPath)) {
    console.error('❌ Native screencap7 binary not found after compilation!');
    return;
  }
  
  ffmpegProcess = spawn(binaryPath, ['8080']);
    
  if (ffmpegProcess) {
    ffmpegProcess.stdout.on('data', (data) => {
      console.log('ScreenCap:', data.toString());
    });
    
    ffmpegProcess.stderr.on('data', (data) => {
      console.log('ScreenCap:', data.toString());
    });
    
    ffmpegProcess.on('close', (code) => {
      console.log('ScreenCap HTTP server closed:', code);
      if (code !== 0) {
        console.log('🔄 ScreenCap crashed, restarting in 2 seconds...');
        setTimeout(() => {
          startServerScreenCapture();
        }, 2000);
      }
    });
    
    console.log('✅ Native macOS HTTP server started on port 8080!');
  }
}

function startServerScreenCaptureWithWindow(cgWindowID) {
  console.log(`🪟 Starting window-specific capture for window ${cgWindowID}...`);
  
  if (platform === 'darwin') {
    const nativeDir = path.join(__dirname, 'native', 'osx');
    const binaryPath = path.join(nativeDir, 'screencap7');
    
    if (!fs.existsSync(binaryPath)) {
      console.error('❌ Native screencap7 binary not found!');
      return;
    }
    
    console.log('🔥 Starting native macOS ScreenCaptureKit HTTP server for window capture...');
    
    // For now, start normally and then use the API to switch to window
    ffmpegProcess = spawn(binaryPath, ['8080']);
    
    if (ffmpegProcess) {
      ffmpegProcess.stdout.on('data', (data) => {
        console.log('ScreenCap:', data.toString());
      });
      
      ffmpegProcess.stderr.on('data', (data) => {
        console.log('ScreenCap:', data.toString());
      });
      
      ffmpegProcess.on('close', (code) => {
        console.log('ScreenCap HTTP server closed:', code);
      });
      
      console.log(`✅ Native macOS HTTP server started for window ${cgWindowID}!`);
      
      // After server starts, try to switch to window capture
      setTimeout(() => {
        switchToWindowCapture(cgWindowID);
      }, 3000); // Give server time to start
    }
  }
}

async function switchToWindowCapture(cgWindowID) {
  try {
    console.log(`🔄 Attempting to switch to window ${cgWindowID}...`);
    
    // Use capture-window endpoint for CGWindowID
    const response = await fetch('http://127.0.0.1:8080/capture-window', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ 
        cgWindowID: parseInt(cgWindowID),
        vp9: false
      })
    });
    
    if (response.ok) {
      console.log(`✅ Successfully switched to window ${cgWindowID}`);
    } else {
      console.log(`❌ Failed to switch to window: ${response.status}`);
    }
  } catch (error) {
    console.log(`❌ Could not switch to window: ${error.message}`);
  }
}

// Start screen capture when server starts
startServerScreenCapture();

const app = express();
const port = 3030;

app.use(cors());
app.use(express.json());

// Endpoint to get window list with optional low-quality screenshots
app.get('/windows', async (req, res) => {
  const { exec } = require('child_process');
  const path = require('path');
  const { promisify } = require('util');
  const execAsync = promisify(exec);
  
  const toolPath = path.join(__dirname, 'native', 'osx', 'list_windows_cg');
  // Screenshots disabled for now  
  const includeScreenshots = false; // req.query.screenshots === 'true';
  
  try {
    const { stdout } = await execAsync(toolPath);
    const windows = JSON.parse(stdout);
    
    if (false && includeScreenshots) {
      console.log('📸 Getting screenshots for', windows.length, 'windows...');
      
      // Performance-optimized: Only get screenshots for first 3 windows to avoid timeouts
      const maxScreenshots = Math.min(windows.length, 3);
      
      for (let i = 0; i < maxScreenshots; i++) {
        const window = windows[i];
        try {
          console.log(`📸 Getting screenshot for window ${window.cgWindowID} (${window.app})`);
          
          // Use native Objective-C screenshot API for optimal performance
          try {
            const response = await fetch('http://127.0.0.1:8080/screenshot', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ cgWindowID: window.cgWindowID })
            });
            
            if (response.ok) {
              const result = await response.json();
              window.screenshot = result.screenshot;
              console.log(`✅ Got native screenshot for ${window.app}`);
            } else {
              console.log(`❌ Native screenshot failed for window ${window.cgWindowID}: ${response.status}`);
            }
          } catch (nativeError) {
            console.log(`❌ Native screenshot error for window ${window.cgWindowID}:`, nativeError.message);
          }
          
        } catch (error) {
          console.log(`❌ Screenshot error for window ${window.cgWindowID}:`, error.message);
        }
      }
      
      res.json(windows);
    } else {
      res.json(windows);
    }
  } catch (error) {
    console.error('Window list error:', error);
    res.status(500).json({ error: 'Failed to get windows' });
  }
});

// Endpoint to switch windows (use the working capture-window endpoint)
app.post('/switch-window', async (req, res) => {
  const { cgWindowID } = req.body;
  
  if (!cgWindowID) {
    res.status(400).json({ error: 'cgWindowID required' });
    return;
  }
  
  console.log('🪟 Window selection:', cgWindowID);
  
  try {
    // Use the working capture-window endpoint
    const response = await fetch('http://127.0.0.1:8080/capture-window', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ 
        cgWindowID: parseInt(cgWindowID),
        vp9: false
      })
    });
    
    if (response.ok) {
      const result = await response.json();
      console.log('✅ Successfully switched to window:', result);
      
      // Update current capture state
      currentCaptureMode = 'window';
      currentWindowID = parseInt(cgWindowID);
      console.log(`📝 Updated capture mode: ${currentCaptureMode}, window: ${currentWindowID}`);
      
      res.json({ 
        status: 'window_capture_started', 
        cgWindowID: parseInt(cgWindowID), 
        message: `Successfully switched to window ${cgWindowID}`
      });
    } else {
      console.log('❌ Failed to switch window:', response.status);
      res.status(500).json({ error: 'Failed to switch to window capture' });
    }
  } catch (error) {
    console.log('❌ Error switching window:', error.message);
    res.status(500).json({ error: 'Could not connect to capture server' });
  }
});

// Endpoint to reset capture mode to desktop
app.post('/reset-capture-mode', (req, res) => {
  currentCaptureMode = 'desktop';
  currentWindowID = null;
  console.log('📝 Reset capture mode to desktop');
  res.json({ status: 'reset', mode: 'desktop' });
});

const wss = new WebSocket.Server({ port: 9090, host: '0.0.0.0' });

class SimpleVNC {
  constructor(ws) {
    this.ws = ws;
    this.ffmpegProcess = null;
  }

  start() {
    const platform = os.platform();
    
    if (platform === 'darwin') {
      console.log('Starting macOS FFmpeg screen capture...');
      
      // Use FFmpeg with reasonable resolution for good performance
      this.ffmpegProcess = spawn('ffmpeg', [
        '-f', 'avfoundation',
        '-pixel_format', 'uyvy422',
        '-framerate', '15',
        '-i', '5:none',
        '-vf', 'scale=1600:900,fps=15',  // 16:9 ratio, good balance
        '-q:v', '5',  // Lower quality for better performance
        '-f', 'image2pipe',
        '-vcodec', 'mjpeg',
        'pipe:1'
      ]);
    } else if (platform === 'linux') {
      console.log('Starting Linux fast JPEG streaming...');
      
      const display = process.env.DISPLAY || ':20.0';
      
      // Start ffmpeg to capture screen and output JPEG frames on Linux
      this.ffmpegProcess = spawn('ffmpeg', [
        '-f', 'x11grab',
        '-video_size', '1600x1200',
        '-framerate', '30',
        '-i', `${display}`,
        '-vf', 'scale=1024:768',
        '-q:v', '3',
        '-f', 'image2pipe',
        '-vcodec', 'mjpeg',
        'pipe:1'
      ]);
    } else {
      throw new Error(`Unsupported platform: ${platform}`);
    }

    let buffer = Buffer.alloc(0);
    
    this.ffmpegProcess.stdout.on('data', (chunk) => {
      buffer = Buffer.concat([buffer, chunk]);
      
      // Look for JPEG markers to split frames
      let start = 0;
      while (true) {
        const jpegStart = buffer.indexOf(Buffer.from([0xFF, 0xD8]), start);
        if (jpegStart === -1) break;
        
        const jpegEnd = buffer.indexOf(Buffer.from([0xFF, 0xD9]), jpegStart + 2);
        if (jpegEnd === -1) break;
        
        // Found complete JPEG frame
        const frame = buffer.slice(jpegStart, jpegEnd + 2);
        
        if (this.ws.readyState === WebSocket.OPEN) {
          this.ws.send(frame);
        }
        
        start = jpegEnd + 2;
      }
      
      // Keep remaining data for next chunk
      if (start > 0) {
        buffer = buffer.slice(start);
      }
    });

    this.ffmpegProcess.stderr.on('data', (data) => {
      console.log('FFmpeg:', data.toString());
    });

    this.ffmpegProcess.on('close', (code) => {
      console.log('FFmpeg process closed:', code);
    });
  }

  stop() {
    if (this.ffmpegProcess) {
      this.ffmpegProcess.kill('SIGTERM');
      this.ffmpegProcess = null;
    }
    if (this.intervalId) {
      clearInterval(this.intervalId);
      this.intervalId = null;
    }
  }

  getScreenshotCommand(filename) {
    const platform = os.platform();
    
    if (platform === 'darwin') {
      return `screencapture -x -C -t jpg "${filename}"`;
    } else if (platform === 'linux') {
      const display = process.env.DISPLAY || ':20.0';
      // Use gnome-screenshot for better performance
      return `DISPLAY=${display} gnome-screenshot -f "${filename}" --delay=0`;
    } else {
      throw new Error(`Unsupported platform: ${platform}`);
    }
  }

  handleInput(data) {
    try {
      console.log('Input received:', data.type, data.x, data.y);
      
      if (data.type === 'mousedown') {
        const cmd = this.getMouseCommand('mousedown', data.x, data.y, data.button);
        console.log('Executing:', cmd);
        exec(cmd);
      } else if (data.type === 'mousemove') {
        const cmd = this.getMouseCommand('mousemove', data.x, data.y);
        exec(cmd);
      } else if (data.type === 'mouseup') {
        const cmd = this.getMouseCommand('mouseup', data.x, data.y, data.button);
        exec(cmd);
      } else if (data.type === 'keydown') {
        const keyCmd = this.getKeyCommand(data);
        if (keyCmd) exec(keyCmd);
      }
    } catch (error) {
      console.error('Input error:', error);
    }
  }

  getMouseCommand(type, x, y, button = 0) {
    const platform = os.platform();
    const roundX = Math.round(x);
    const roundY = Math.round(y);
    
    if (platform === 'darwin') {
      if (type === 'mousedown') {
        return `cliclick c:${roundX},${roundY}`;  // Simple click
      } else if (type === 'mousemove') {
        return `cliclick m:${roundX},${roundY}`;
      } else if (type === 'mouseup') {
        return `cliclick m:${roundX},${roundY}`;  // Just move for mouseup
      }
    } else if (platform === 'linux') {
      const display = process.env.DISPLAY || ':20.0';
      const mouseBtn = button === 2 ? 3 : (button === 1 ? 2 : 1); // Convert button mapping
      
      if (type === 'mousedown') {
        return `DISPLAY=${display} xdotool mousemove ${roundX} ${roundY} mousedown ${mouseBtn}`;
      } else if (type === 'mousemove') {
        return `DISPLAY=${display} xdotool mousemove ${roundX} ${roundY}`;
      } else if (type === 'mouseup') {
        return `DISPLAY=${display} xdotool mousemove ${roundX} ${roundY} mouseup ${mouseBtn}`;
      }
    } else {
      throw new Error(`Unsupported platform: ${platform}`);
    }
  }

  getKeyCommand(data) {
    const platform = os.platform();
    
    if (platform === 'darwin') {
      let key = data.key;
      if (data.ctrlKey || data.metaKey) key = 'cmd+' + key.toLowerCase();
      return `cliclick kp:${key}`;
    } else if (platform === 'linux') {
      const display = process.env.DISPLAY || ':20.0';
      let key = data.key;
      
      // Handle special keys for xdotool
      if (key === ' ') key = 'space';
      else if (key === 'Enter') key = 'Return';
      else if (key === 'Backspace') key = 'BackSpace';
      else if (key === 'Tab') key = 'Tab';
      else if (key === 'Escape') key = 'Escape';
      else if (key.length > 1) return null; // Skip other special keys for now
      
      let modifiers = '';
      if (data.ctrlKey) modifiers += 'ctrl+';
      if (data.altKey) modifiers += 'alt+';
      if (data.metaKey) modifiers += 'super+';
      
      return `DISPLAY=${display} xdotool key ${modifiers}${key}`;
    } else {
      throw new Error(`Unsupported platform: ${platform}`);
    }
  }
}

// Stream server screen to clients via HTTP API polling
let streamingInterval = null;

function startHTTPStreaming() {
  if (platform === 'darwin' && !streamingInterval) {
    // Poll the HTTP API for frames and send to WebSocket clients
    streamingInterval = setInterval(async () => {
      try {
        const response = await fetch('http://127.0.0.1:8080/frame');
        if (response.ok) {
          const frameBuffer = Buffer.from(await response.arrayBuffer());
          
          // Send to all connected clients
          wss.clients.forEach(client => {
            if (client.readyState === WebSocket.OPEN) {
              client.send(frameBuffer);
            }
          });
        }
      } catch (error) {
        // HTTP server not ready yet, continue polling
      }
    }, 33); // ~30 FPS
    
    console.log('✅ HTTP API streaming started at 30 FPS');
  }
}

// Start HTTP streaming after a short delay for server startup
setTimeout(startHTTPStreaming, 2000);

// Handle client connections and input
wss.on('connection', ws => {
  console.log('Client connected - streaming server screen automatically');

  ws.on('message', async message => {
    try {
      const data = JSON.parse(message);

      if (data.type === 'input') {
        // Handle remote input (mouse/keyboard)
        handleRemoteInput(data.data);
      }
    } catch (error) {
      console.error('Message error:', error);
    }
  });
});

async function handleRemoteInput(data) {
  try {
    console.log('Input received:', data.type, data.x, data.y);
    
    if (data.type === 'mousedown' || data.type === 'click') {
      await sendClickToNativeBinary(data.x, data.y, data.canvasWidth, data.canvasHeight);
    } else if (data.type === 'keydown') {
      await sendKeyToNativeBinary(data);
    }
  } catch (error) {
    console.error('Input error:', error);
  }
}

// Cache display info
let cachedDisplayInfo = null;

// Coordinate calibration offsets (adjust these if clicks are slightly off)
const CLICK_OFFSET_X = 0;  // Positive = click more to the right
const CLICK_OFFSET_Y = 0;  // Positive = click more down

// Debug mode for coordinate testing
const DEBUG_COORDINATES = process.env.DEBUG_COORDS === 'true';

async function getDisplayInfo() {
  if (cachedDisplayInfo) {
    return cachedDisplayInfo;
  }
  
  try {
    const response = await fetch('http://127.0.0.1:8080/display');
    if (response.ok) {
      cachedDisplayInfo = await response.json();
      return cachedDisplayInfo;
    }
  } catch (error) {
    console.log('❌ Could not get display info:', error.message);
  }
  
  // Fallback to default if API fails
  return { 
    width: 1920,          // Logical width
    height: 1080,         // Logical height
    physicalWidth: 3840,  // Physical width (Retina)
    physicalHeight: 2160, // Physical height (Retina)
    scaleFactor: 2        // Retina scale factor
  };
}

async function sendClickToNativeBinary(x, y, canvasWidth, canvasHeight) {
  const platform = os.platform();
  
  let scaledX = x;
  let scaledY = y;
  
  if (platform === 'darwin' && canvasWidth && canvasHeight) {
    console.log('Current capture mode:', currentCaptureMode, 'WindowID:', currentWindowID);
    
    // Get display info for scaling calculations
    const displayInfo = await getDisplayInfo();
    const scaleFactor = displayInfo.scaleFactor || 2; // Default to 2x for Retina
    
    if (currentCaptureMode === 'window') {
      // Window capture: Need to handle Retina scaling
      // The canvas might be at 2x resolution, but clicks need logical coordinates
      
      // First, check if we're dealing with a Retina capture
      // Windows smaller than full screen are often captured at 2x on Retina displays
      const isRetinaCapture = canvasWidth < displayInfo.physicalWidth && canvasHeight < displayInfo.physicalHeight;
      
      if (isRetinaCapture) {
        // For Retina window captures, we need to scale down by the display scale factor
        // because the window is captured at physical resolution but clicks use logical coordinates
        scaledX = Math.round(x / scaleFactor) + CLICK_OFFSET_X;
        scaledY = Math.round(y / scaleFactor) + CLICK_OFFSET_Y;
        console.log(`Window capture Retina scaling: ${x},${y} -> ${scaledX},${scaledY} (scale: ${scaleFactor}x, canvas: ${canvasWidth}x${canvasHeight})`);
      } else {
        // Non-Retina or full-size window, use coordinates as-is
        scaledX = Math.round(x) + CLICK_OFFSET_X;
        scaledY = Math.round(y) + CLICK_OFFSET_Y;
        console.log(`Window capture direct: ${x},${y} -> ${scaledX},${scaledY} (canvas: ${canvasWidth}x${canvasHeight})`);
      }
    } else {
      // Desktop capture: The coordinates should match the logical display coordinates
      // ScreenCaptureKit captures at physical resolution, but we need logical coordinates for clicks
      if (canvasWidth === displayInfo.physicalWidth && canvasHeight === displayInfo.physicalHeight) {
        // Full desktop at physical resolution - scale down to logical coordinates
        scaledX = Math.round(x / scaleFactor) + CLICK_OFFSET_X;
        scaledY = Math.round(y / scaleFactor) + CLICK_OFFSET_Y;
        console.log(`Desktop capture scaling: ${x},${y} -> ${scaledX},${scaledY} (scale: ${scaleFactor}x, canvas: ${canvasWidth}x${canvasHeight})`);
      } else {
        // Already at logical resolution or unknown state
        scaledX = Math.round(x) + CLICK_OFFSET_X;
        scaledY = Math.round(y) + CLICK_OFFSET_Y;
        console.log(`Desktop capture direct: ${x},${y} -> ${scaledX},${scaledY} (canvas: ${canvasWidth}x${canvasHeight})`);
      }
    }
    
    // Send click command to HTTP API - use window-targeted endpoint if in window mode
    try {
      let endpoint, payload;
      
      if (currentCaptureMode === 'window' && currentWindowID) {
        endpoint = 'http://127.0.0.1:8080/click-window';
        payload = { x: scaledX, y: scaledY, cgWindowID: currentWindowID };
        console.log(`🎯 Sending targeted click to window ${currentWindowID}: ${scaledX},${scaledY}`);
      } else {
        endpoint = 'http://127.0.0.1:8080/click';
        payload = { x: scaledX, y: scaledY };
        console.log(`🖱️ Sending global click: ${scaledX},${scaledY}`);
      }
      
      const response = await fetch(endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      });
      
      if (response.ok) {
        const result = await response.json();
        console.log(`✅ Click sent via HTTP API: ${result.status}`);
      } else {
        console.log('❌ HTTP API click failed:', response.status);
      }
    } catch (error) {
      console.log('❌ HTTP API not available:', error.message);
    }
  } else if (platform === 'linux') {
    const display = process.env.DISPLAY || ':20.0';
    const cmd = `DISPLAY=${display} xdotool mousemove ${scaledX} ${scaledY} click 1`;
    console.log('Executing:', cmd);
    exec(cmd);
  }
}

async function sendKeyToNativeBinary(data) {
  const platform = os.platform();
  
  if (platform === 'darwin') {
    // Ensure display info is cached for future coordinate scaling
    await getDisplayInfo();
    
    // Send key command to HTTP API - use window-targeted endpoint if in window mode
    try {
      let endpoint, payload;
      
      if (currentCaptureMode === 'window' && currentWindowID) {
        endpoint = 'http://127.0.0.1:8080/key-window';
        payload = { key: data.key, cgWindowID: currentWindowID };
        console.log(`🎯 Sending targeted key '${data.key}' to window ${currentWindowID}`);
      } else {
        endpoint = 'http://127.0.0.1:8080/key';
        payload = { key: data.key };
        console.log(`⌨️ Sending global key: ${data.key}`);
      }
      
      const response = await fetch(endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      });
      
      if (response.ok) {
        const result = await response.json();
        console.log(`✅ Key sent via HTTP API: ${result.status}`);
      } else {
        console.log('❌ HTTP API key failed:', response.status);
      }
    } catch (error) {
      console.log('❌ HTTP API not available:', error.message);
    }
  } else if (platform === 'linux') {
    const keyCmd = getKeyCommand(data);
    if (keyCmd) exec(keyCmd);
  }
}

function getKeyCommand(data) {
  const platform = os.platform();
  
  if (platform === 'linux') {
    const display = process.env.DISPLAY || ':20.0';
    let key = data.key;
    
    if (key === ' ') key = 'space';
    else if (key === 'Enter') key = 'Return';
    else if (key === 'Backspace') key = 'BackSpace';
    else if (key.length > 1) return null;
    
    let modifiers = '';
    if (data.ctrlKey) modifiers += 'ctrl+';
    if (data.altKey) modifiers += 'alt+';
    if (data.metaKey) modifiers += 'super+';
    
    return `DISPLAY=${display} xdotool key ${modifiers}${key}`;
  }
  return null;
}

// Route for coordinate testing - starts fullscreen test app
app.get('/coordtest', (req, res) => {
  const windowed = req.query.windowed === 'true';
  console.log('🎯 Starting coordinate test app' + (windowed ? ' (windowed 500x500)' : ' (fullscreen)') + '...');
  
  // Start the appropriate test app
  const testAppName = windowed ? 'coordinate_test_window' : 'coordinate_test';
  const testAppPath = path.join(__dirname, 'native', 'osx', testAppName);
  const testProcess = spawn(testAppPath, [], {
    stdio: ['ignore', 'pipe', 'pipe']
  });
  
  // Log output to server.log
  testProcess.stdout.on('data', (data) => {
    console.log('CoordTest:', data.toString().trim());
  });
  
  testProcess.stderr.on('data', (data) => {
    console.log('CoordTest:', data.toString().trim());
  });
  
  testProcess.on('close', (code) => {
    console.log('CoordTest: App closed with code', code);
  });
  
  res.json({ 
    status: 'Coordinate test app started', 
    pid: testProcess.pid,
    mode: windowed ? 'windowed (500x500)' : 'fullscreen'
  });
});

// Route for coordinate debugging info
app.get('/coord-info', async (req, res) => {
  const displayInfo = await getDisplayInfo();
  
  res.json({
    captureMode: currentCaptureMode,
    windowID: currentWindowID,
    displayInfo: displayInfo,
    debugMode: DEBUG_COORDINATES,
    calibrationOffsets: {
      x: CLICK_OFFSET_X,
      y: CLICK_OFFSET_Y
    },
    instructions: {
      enableDebug: 'Set DEBUG_COORDS=true environment variable to enable visual debugging',
      testDesktop: 'Visit /?test=desktop to test desktop capture',
      testWindow: 'Visit /?test=window to test window capture',
      coordTest: 'Visit /coordtest to start coordinate test app'
    }
  });
});


// VP9 streaming page
app.get('/vp9', (req, res) => {
  res.sendFile(__dirname + '/vp9-client.html');
});



// Route for clients - shows grid to select application
app.get('/', (req, res) => {
  res.send(`
<!DOCTYPE html>
<html>
<head>
  <title>Remote Desktop - Select Application</title>
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <style>
    * { box-sizing: border-box; }
    body { 
      margin: 0; padding: 0; 
      background: linear-gradient(135deg, #0a0a0a 0%, #1a1a2e 100%); 
      color: white; 
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; 
      min-height: 100vh;
    }
    
    .container { padding: 20px; max-width: 1600px; margin: 0 auto; }
    
    .header { 
      text-align: center; margin-bottom: 40px; 
      background: rgba(255,255,255,0.05); 
      backdrop-filter: blur(10px);
      padding: 30px; border-radius: 20px; 
      border: 1px solid rgba(255,255,255,0.1);
    }
    .header h1 { 
      margin: 0 0 10px 0; font-size: 2.5rem; font-weight: 700; 
      background: linear-gradient(45deg, #667eea 0%, #764ba2 100%);
      -webkit-background-clip: text; -webkit-text-fill-color: transparent;
      background-clip: text;
    }
    .header p { margin: 0; opacity: 0.8; font-size: 1.1rem; }
    
    .search-bar {
      margin: 20px 0 30px 0; position: relative;
    }
    .search-input {
      width: 100%; max-width: 400px; margin: 0 auto; display: block;
      padding: 12px 20px 12px 50px; border: none; border-radius: 25px;
      background: rgba(255,255,255,0.1); color: white; font-size: 16px;
      backdrop-filter: blur(10px); border: 1px solid rgba(255,255,255,0.2);
    }
    .search-input::placeholder { color: rgba(255,255,255,0.6); }
    .search-icon { 
      position: absolute; left: 50%; transform: translateX(-50%); margin-left: -180px;
      top: 50%; transform: translateY(-50%) translateX(-50%); margin-left: -180px;
      font-size: 20px; color: rgba(255,255,255,0.6);
    }
    
    .grid { 
      display: grid; 
      grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); 
      gap: 24px; 
    }
    
    .app-card { 
      background: rgba(255,255,255,0.08); 
      backdrop-filter: blur(15px);
      border-radius: 20px; 
      padding: 24px; 
      cursor: pointer; 
      transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
      border: 1px solid rgba(255,255,255,0.1);
      position: relative;
      overflow: hidden;
    }
    
    .app-card::before {
      content: '';
      position: absolute;
      top: 0; left: 0; right: 0; bottom: 0;
      background: linear-gradient(45deg, transparent, rgba(255,255,255,0.05), transparent);
      opacity: 0; transition: opacity 0.3s ease;
    }
    
    .app-card:hover { 
      transform: translateY(-8px) scale(1.02); 
      border-color: rgba(102, 126, 234, 0.5);
      box-shadow: 0 20px 40px rgba(102, 126, 234, 0.2);
    }
    .app-card:hover::before { opacity: 1; }
    
    .app-card.selected { 
      border-color: #00ff88; 
      background: rgba(0, 255, 136, 0.1);
      box-shadow: 0 0 30px rgba(0, 255, 136, 0.3);
    }
    
    .app-icon { 
      font-size: 3rem; margin-bottom: 16px; 
      display: flex; align-items: center; justify-content: space-between;
    }
    .app-icon .icon { font-size: 3rem; }
    .app-icon .badge { 
      font-size: 0.8rem; background: rgba(102, 126, 234, 0.8); 
      padding: 4px 12px; border-radius: 15px; font-weight: 600;
    }
    
    .app-name { 
      font-weight: 700; margin-bottom: 8px; font-size: 1.3rem; 
      display: -webkit-box; -webkit-line-clamp: 2; 
      -webkit-box-orient: vertical; overflow: hidden;
    }
    
    .app-details {
      display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin: 16px 0;
    }
    .detail-item {
      background: rgba(255,255,255,0.05); padding: 8px 12px; border-radius: 8px;
      font-size: 0.85rem; text-align: center;
    }
    .detail-label { opacity: 0.7; font-size: 0.75rem; display: block; }
    .detail-value { font-weight: 600; margin-top: 2px; }
    
    .app-preview { 
      width: 100%; height: 140px; background: rgba(0,0,0,0.3); 
      border-radius: 12px; margin: 16px 0;
      display: flex; align-items: center; justify-content: center; 
      border: 2px dashed rgba(255,255,255,0.2);
      position: relative; overflow: hidden;
    }
    
    .preview-placeholder {
      text-align: center; color: rgba(255,255,255,0.6);
    }
    .preview-placeholder .icon { font-size: 2rem; margin-bottom: 8px; display: block; }
    .preview-placeholder .text { font-size: 0.9rem; }
    
    .status { 
      text-align: center; margin: 30px 0; padding: 20px; 
      background: rgba(255,255,255,0.05); border-radius: 15px;
      backdrop-filter: blur(10px); border: 1px solid rgba(255,255,255,0.1);
    }
    
    .viewer { 
      display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; 
      background: #000; z-index: 1000; 
    }
    .viewer-header { 
      position: absolute; top: 20px; right: 20px; z-index: 1001; 
    }
    .back-btn { 
      background: linear-gradient(45deg, #ff4757, #ff6b7a); 
      color: white; border: none; padding: 12px 20px; 
      border-radius: 10px; cursor: pointer; font-weight: 700;
      transition: all 0.2s ease; font-size: 14px;
      box-shadow: 0 4px 15px rgba(255, 71, 87, 0.3);
    }
    .back-btn:hover { 
      transform: translateY(-2px); 
      box-shadow: 0 8px 25px rgba(255, 71, 87, 0.4);
    }
    
    .viewer-info-panel {
      position: fixed; bottom: 20px; left: 50%; transform: translateX(-50%);
      background: rgba(0,0,0,0.85); backdrop-filter: blur(15px);
      border-radius: 15px; color: white; z-index: 1001;
      transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
      border: 1px solid rgba(255,255,255,0.1);
      min-width: 300px; max-width: 500px;
    }
    
    .viewer-info-panel.collapsed {
      transform: translateX(-50%) translateY(calc(100% - 50px));
    }
    
    .info-panel-header {
      padding: 12px 20px; cursor: pointer; display: flex; 
      justify-content: space-between; align-items: center;
      border-bottom: 1px solid rgba(255,255,255,0.1);
    }
    
    .info-panel-content {
      padding: 15px 20px; font-family: 'SF Mono', monospace; font-size: 14px;
      transition: all 0.3s ease;
    }
    
    .viewer-info-panel.collapsed .info-panel-content {
      max-height: 0; padding-top: 0; padding-bottom: 0; overflow: hidden;
    }
    
    .info-panel-header .title {
      font-weight: 600; font-size: 14px;
    }
    
    .info-panel-header .toggle {
      font-size: 16px; transition: transform 0.3s ease;
    }
    
    .viewer-info-panel.collapsed .toggle {
      transform: rotate(180deg);
    }
    
    .info-item {
      margin: 8px 0; display: flex; justify-content: space-between;
    }
    
    .info-label {
      opacity: 0.7;
    }
    
    .info-value {
      font-weight: 600;
    }
    .viewer-canvas { cursor: crosshair; }
    
    @keyframes pulse {
      0%, 100% { opacity: 1; }
      50% { opacity: 0.5; }
    }
    .loading { animation: pulse 1.5s infinite; }
    
    @media (max-width: 768px) {
      .container { padding: 15px; }
      .grid { grid-template-columns: 1fr; gap: 16px; }
      .header h1 { font-size: 2rem; }
      .app-card { padding: 20px; }
    }
  </style>
</head>
<body>
  <div id="grid-view" class="container">
    <div class="header">
      <h1>🚀 Remote Desktop Control Center</h1>
      <p>Select any application or desktop environment to control remotely</p>
      
      <div class="mode-selector" style="margin: 20px 0; display: flex; justify-content: center; gap: 15px;">
        <button class="mode-btn active" id="websocket-mode" onclick="selectMode('websocket')" style="
          background: linear-gradient(45deg, #667eea, #764ba2);
          color: white; border: none; padding: 15px 25px; border-radius: 12px;
          cursor: pointer; font-weight: 600; font-size: 14px;
          transition: all 0.3s ease; display: flex; flex-direction: column; align-items: center; gap: 5px;
          border: 2px solid #00ff88;
        ">
          🌐 WebSocket Mode
          <small style="opacity: 0.8; font-size: 11px;">Stable • 200-500ms latency</small>
        </button>
        <button class="mode-btn" id="vp9-mode" onclick="selectMode('vp9')" style="
          background: linear-gradient(45deg, #667eea, #764ba2);
          color: white; border: none; padding: 15px 25px; border-radius: 12px;
          cursor: pointer; font-weight: 600; font-size: 14px;
          transition: all 0.3s ease; display: flex; flex-direction: column; align-items: center; gap: 5px;
          border: 2px solid transparent;
        ">
          🎥 High Quality
          <small style="opacity: 0.8; font-size: 11px;">Full res • 95% quality</small>
        </button>
      </div>
      
      <div class="search-bar">
        <div class="search-icon">🔍</div>
        <input type="text" class="search-input" id="search-input" placeholder="Search applications and windows..." oninput="filterApps()">
      </div>
    </div>
    
    <div class="grid" id="apps-grid"></div>
    <div class="status" id="status">
      <div class="loading">📡 Loading applications and windows...</div>
    </div>
  </div>

  <div id="viewer" class="viewer">
    <div class="viewer-header">
      <button class="back-btn" onclick="showGrid()">← Back to Grid</button>
    </div>
    
    <div style="display:flex; justify-content:center; align-items:center; width:100%; height:100vh;">
      <canvas id="canvas" class="viewer-canvas"></canvas>
    </div>
    
    <div id="viewer-info-panel" class="viewer-info-panel">
      <div class="info-panel-header" onclick="toggleInfoPanel()">
        <span class="title">Remote Control Info</span>
        <span class="toggle">▼</span>
      </div>
      <div class="info-panel-content">
        <div class="info-item">
          <span class="info-label">Controlling:</span>
          <span class="info-value" id="viewer-app-name">Desktop</span>
        </div>
        <div class="info-item">
          <span class="info-label">Frame Rate:</span>
          <span class="info-value" id="viewer-fps">FPS: 0</span>
        </div>
        <div class="info-item">
          <span class="info-label">Canvas Size:</span>
          <span class="info-value" id="canvas-size">0x0</span>
        </div>
        <div class="info-item">
          <span class="info-label">Display Size:</span>
          <span class="info-value" id="display-size">0x0</span>
        </div>
        <div class="info-item">
          <span class="info-label">Mouse:</span>
          <span class="info-value">Click anywhere to control</span>
        </div>
        <div class="info-item">
          <span class="info-label">Keyboard:</span>
          <span class="info-value">Type normally to send keys</span>
        </div>
      </div>
    </div>
  </div>

  <script>
    let ws = null;
    let apps = [];
    let selectedApp = null;
    let frameCount = 0;
    let lastSecond = Date.now();
    
    // Debug mode flag
    window.DEBUG_COORDINATES = ${DEBUG_COORDINATES};
    
    // Dynamic host detection for remote access
    const currentHost = window.location.hostname;
    const nativeApiUrl = 'http://' + currentHost + ':8080';
    const wsUrl = 'ws://' + currentHost + ':9090';
    
    // Mode selection variables
    let selectedMode = 'websocket'; // Default mode
    
    function selectMode(mode) {
      selectedMode = mode;
      
      // Update button styles
      document.getElementById('websocket-mode').style.border = mode === 'websocket' ? '2px solid #00ff88' : '2px solid transparent';
      document.getElementById('vp9-mode').style.border = mode === 'vp9' ? '2px solid #00ff88' : '2px solid transparent';
      
      console.log('🎯 Selected mode:', mode);
      
      // Update status message
      if (mode === 'vp9') {
        document.getElementById('status').innerHTML = 
          '<div style="display: flex; align-items: center; justify-content: center; gap: 10px;">' +
            '<span style="font-size: 1.2rem;">🎥</span>' +
            '<span><strong>High Quality Mode Selected</strong> - Full resolution, 95% JPEG quality!</span>' +
          '</div>';
      } else {
        document.getElementById('status').innerHTML = 
          '<div style="display: flex; align-items: center; justify-content: center; gap: 10px;">' +
            '<span style="font-size: 1.2rem;">🌐</span>' +
            '<span><strong>WebSocket Mode Selected</strong> - Stable streaming mode</span>' +
          '</div>';
      }
    }
    
    // Load applications grid with screenshots
    async function loadApps() {
      try {
        // Get windows without screenshots (disabled for now)
        const windowsResponse = await fetch('/windows');
        const windowsData = await windowsResponse.json();
        
        // Build apps array
        apps = [];
        
        // Add full desktop first
        apps.push({
          id: 0,
          name: 'Full Desktop',
          type: 'desktop'
        });
        
        // Add individual windows
        windowsData.forEach((window, index) => {
          apps.push({
            id: index + 1, // Start from 1 to avoid conflict with desktop
            name: window.app + ': ' + window.title,
            type: 'window',
            cgWindowID: window.cgWindowID,
            title: window.title,
            app: window.app,
            position: window.position,
            size: window.size,
            screenshot: window.screenshot // Include screenshot if available
          });
        });
        
        renderGrid();
        document.getElementById('status').innerHTML = 
          '<div style="display: flex; align-items: center; justify-content: center; gap: 10px;">' +
            '<span style="font-size: 1.2rem;">✅</span>' +
            '<span>Found <strong>' + apps.length + '</strong> items (' + (apps.length - 1) + ' windows + desktop)</span>' +
          '</div>';
      } catch (error) {
        document.getElementById('status').innerHTML = 
          '<div style="display: flex; align-items: center; justify-content: center; gap: 10px;">' +
            '<span style="font-size: 1.2rem;">❌</span>' +
            '<span>Error: Cannot load windows</span>' +
          '</div>';
        console.error('Failed to load windows:', error);
      }
    }
    
    function renderGrid() {
      const grid = document.getElementById('apps-grid');
      grid.innerHTML = '';
      
      apps.forEach(app => {
        const card = document.createElement('div');
        card.className = 'app-card';
        card.onclick = () => selectApp(app);
        
        let icon, badge, details = '';
        if (app.type === 'desktop') {
          icon = '🖥️';
          badge = 'DESKTOP';
          details = 
            '<div class="detail-item">' +
              '<span class="detail-label">Type</span>' +
              '<div class="detail-value">Full Screen</div>' +
            '</div>' +
            '<div class="detail-item">' +
              '<span class="detail-label">Mode</span>' +
              '<div class="detail-value">Primary Display</div>' +
            '</div>';
        } else if (app.type === 'window') {
          // Smart icon selection based on app name
          if (app.app.toLowerCase().includes('chrome') || app.app.toLowerCase().includes('firefox') || app.app.toLowerCase().includes('safari')) {
            icon = '🌐';
          } else if (app.app.toLowerCase().includes('terminal') || app.app.toLowerCase().includes('iterm')) {
            icon = '⚡';
          } else if (app.app.toLowerCase().includes('code') || app.app.toLowerCase().includes('cursor') || app.app.toLowerCase().includes('xcode')) {
            icon = '💻';
          } else if (app.app.toLowerCase().includes('slack') || app.app.toLowerCase().includes('discord') || app.app.toLowerCase().includes('teams')) {
            icon = '💬';
          } else if (app.app.toLowerCase().includes('music') || app.app.toLowerCase().includes('spotify')) {
            icon = '🎵';
          } else if (app.app.toLowerCase().includes('mail')) {
            icon = '📧';
          } else if (app.app.toLowerCase().includes('finder')) {
            icon = '📁';
          } else {
            icon = '🪟';
          }
          badge = 'WINDOW';
          details = 
            '<div class="detail-item">' +
              '<span class="detail-label">Size</span>' +
              '<div class="detail-value">' + app.size.width + '×' + app.size.height + '</div>' +
            '</div>' +
            '<div class="detail-item">' +
              '<span class="detail-label">Position</span>' +
              '<div class="detail-value">(' + app.position.x + ', ' + app.position.y + ')</div>' +
            '</div>';
        }
        
        card.innerHTML = 
          '<div class="app-icon">' +
            '<span class="icon">' + icon + '</span>' +
            '<span class="badge">' + badge + '</span>' +
          '</div>' +
          '<div class="app-name">' + app.name + '</div>' +
          '<div class="app-details">' +
            details +
          '</div>' +
          '<div class="app-preview">' +
            (app.screenshot 
              ? '<img src="' + app.screenshot + '" style="width:100%; height:100%; object-fit:cover; border-radius:8px;" alt="Preview">'
              : '<div class="preview-placeholder">' +
                   '<span class="icon">📸</span>' +
                   '<div class="text">Click to connect and view</div>' +
                 '</div>'
            ) +
          '</div>';
        
        grid.appendChild(card);
      });
    }
    
    function filterApps() {
      const query = document.getElementById('search-input').value.toLowerCase();
      const cards = document.querySelectorAll('.app-card');
      
      cards.forEach(card => {
        const appName = card.querySelector('.app-name').textContent.toLowerCase();
        if (appName.includes(query)) {
          card.style.display = 'block';
        } else {
          card.style.display = 'none';
        }
      });
    }
    
    async function selectApp(app) {
      selectedApp = app;
      
      // Add visual feedback
      document.querySelectorAll('.app-card').forEach(card => card.classList.remove('selected'));
      event.currentTarget.classList.add('selected');
      
      // Show loading state
      document.getElementById('status').innerHTML = 
        '<div class="loading" style="display: flex; align-items: center; justify-content: center; gap: 10px;">' +
          '<span style="font-size: 1.2rem;">🚀</span>' +
          '<span>Connecting to <strong>' + app.name + '</strong>...</span>' +
        '</div>';
      
      document.getElementById('viewer-app-name').textContent = 'Controlling: ' + app.name;
      
      // Start capture for this app based on selected mode
      try {
        if (selectedMode === 'vp9') {
          // VP9 Mode - redirect to VP9 interface
          console.log('🎥 Starting VP9 mode for', app.name);
          
          document.getElementById('status').innerHTML = 
            '<div style="display: flex; align-items: center; justify-content: center; gap: 10px;">' +
              '<span style="font-size: 1.2rem;">🎥</span>' +
              '<span>Launching <strong>High Quality</strong> mode...</span>' +
            '</div>';
          
          // Store selected app for VP9 mode
          localStorage.setItem('selectedApp', JSON.stringify(app));
          
          // Redirect to VP9 interface
          setTimeout(() => {
            window.location.href = '/vp9';
          }, 1000);
          
        } else {
          // WebSocket Mode - original implementation
          if (app.type === 'desktop') {
            // For desktop, use the native HTTP API and reset capture mode
            currentCaptureMode = 'desktop';
            currentWindowID = null;
            console.log('📝 Set capture mode to desktop');
            
            const response = await fetch(nativeApiUrl + '/capture', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ 
                type: 0, 
                index: 0, 
                vp9: false 
              })
            });
            
            if (response.ok) {
              document.getElementById('status').innerHTML = 
                '<div style="display: flex; align-items: center; justify-content: center; gap: 10px;">' +
                  '<span style="font-size: 1.2rem;">🎯</span>' +
                  '<span>Successfully connected to <strong>' + app.name + '</strong></span>' +
                '</div>';
              setTimeout(() => {
                showViewer();
                connectWebSocket();
              }, 800);
            } else {
              document.getElementById('status').innerHTML = 
                '<div style="display: flex; align-items: center; justify-content: center; gap: 10px;">' +
                  '<span style="font-size: 1.2rem;">❌</span>' +
                  '<span>Failed to start desktop capture</span>' +
                '</div>';
            }
          } else {
            // For individual windows, use simple script approach (Carmack-style: use what works)
            const response = await fetch('/switch-window', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ cgWindowID: app.cgWindowID })
            });
            
            if (response.ok) {
              const result = await response.json();
              console.log('Window switched:', result.message);
              document.getElementById('status').innerHTML = 
                '<div style="display: flex; align-items: center; justify-content: center; gap: 10px;">' +
                  '<span style="font-size: 1.2rem;">🪟</span>' +
                  '<span>Successfully connected to <strong>' + app.name + '</strong></span>' +
                '</div>';
              setTimeout(() => {
                showViewer();
                connectWebSocket();
              }, 800);
            } else {
              document.getElementById('status').innerHTML = 
                '<div style="display: flex; align-items: center; justify-content: center; gap: 10px;">' +
                  '<span style="font-size: 1.2rem;">❌</span>' +
                  '<span>Failed to switch to window</span>' +
                '</div>';
            }
          }
        }
      } catch (error) {
        alert('Error starting capture: ' + error.message);
      }
    }
    
    function showGrid() {
      document.getElementById('grid-view').style.display = 'block';
      document.getElementById('viewer').style.display = 'none';
      
      if (ws) {
        ws.close();
        ws = null;
      }
      
      // Reset capture mode to desktop when returning to grid
      fetch('/reset-capture-mode', { method: 'POST' })
        .then(() => console.log('📝 Reset to desktop capture mode'))
        .catch(err => console.log('❌ Failed to reset capture mode:', err));
      
      // Refresh the grid
      loadApps();
    }
    
    function showViewer() {
      document.getElementById('grid-view').style.display = 'none';
      document.getElementById('viewer').style.display = 'block';
      
      // Start with info panel collapsed after a few seconds
      setTimeout(() => {
        document.getElementById('viewer-info-panel').classList.add('collapsed');
      }, 3000);
    }
    
    function toggleInfoPanel() {
      const panel = document.getElementById('viewer-info-panel');
      panel.classList.toggle('collapsed');
    }
    
    function connectWebSocket() {
      ws = new WebSocket(wsUrl);
      ws.binaryType = 'arraybuffer';
      
      ws.onopen = () => {
        console.log('Connected to streaming server');
      };
      
      ws.onmessage = (event) => {
        if (typeof event.data === 'string') {
          console.log('Server message:', event.data);
        } else {
          displayFrame(event.data);
        }
      };
      
      ws.onclose = () => {
        console.log('Disconnected from streaming server');
      };
    }
    
    function displayFrame(frameData) {
      const canvas = document.getElementById('canvas');
      const ctx = canvas.getContext('2d');
      const blob = new Blob([frameData], {type: 'image/jpeg'});
      const img = new Image();
      
      img.onload = () => {
        // Only scale down if too large, never scale up for accurate coordinates
        const maxWidth = window.innerWidth - 40;
        const maxHeight = window.innerHeight - 80;
        const aspectRatio = img.width / img.height;
        
        let displayWidth = img.width;
        let displayHeight = img.height;
        
        console.log('Image loaded: ' + img.width + 'x' + img.height + ' | Viewport max: ' + maxWidth + 'x' + maxHeight);
        
        // Check if this might be a Retina capture of a small window
        // A 500x500 window might be captured at ~1800x1900 on Retina
        const isLikelyRetinaWindow = img.width > 1000 && img.width < 2500 && 
                                     img.height > 1000 && img.height < 2500;
        
        if (isLikelyRetinaWindow) {
          console.log('Detected likely Retina window capture, will scale to fit');
          // Always scale Retina windows to fit viewport
          const scaleX = maxWidth / displayWidth;
          const scaleY = maxHeight / displayHeight;
          const scale = Math.min(scaleX, scaleY);
          
          displayWidth = displayWidth * scale;
          displayHeight = displayHeight * scale;
        } else if (displayWidth > maxWidth || displayHeight > maxHeight) {
          // Only scale DOWN if the image is larger than viewport
          const scaleX = maxWidth / displayWidth;
          const scaleY = maxHeight / displayHeight;
          const scale = Math.min(scaleX, scaleY);
          
          displayWidth = displayWidth * scale;
          displayHeight = displayHeight * scale;
        }
        
        console.log('Display size: ' + displayWidth + 'x' + displayHeight + ' (scaled: ' + (displayWidth !== img.width) + ')');
        
        // Set canvas to actual image dimensions
        canvas.width = img.width;
        canvas.height = img.height;
        canvas.style.width = displayWidth + 'px';
        canvas.style.height = displayHeight + 'px';
        ctx.drawImage(img, 0, 0);
        
        // Update debug info
        document.getElementById('canvas-size').textContent = canvas.width + 'x' + canvas.height;
        updateFPS();
      };
      
      img.src = URL.createObjectURL(blob);
    }
    
    async function updateDisplayInfo() {
      try {
        const response = await fetch(nativeApiUrl + '/display');
        if (response.ok) {
          const displayInfo = await response.json();
          document.getElementById('display-size').textContent = displayInfo.width + 'x' + displayInfo.height;
        }
      } catch (error) {
        // Ignore display info errors
      }
    }
    
    function updateFPS() {
      frameCount++;
      const now = Date.now();
      if (now - lastSecond >= 1000) {
        document.getElementById('viewer-fps').textContent = 'FPS: ' + frameCount;
        frameCount = 0;
        lastSecond = now;
      }
    }
    
    function getScaledCoords(e) {
      const canvas = document.getElementById('canvas');
      const rect = canvas.getBoundingClientRect();
      
      // Scale from display size to canvas size
      const scaleX = canvas.width / rect.width;
      const scaleY = canvas.height / rect.height;
      
      const x = (e.clientX - rect.left) * scaleX;
      const y = (e.clientY - rect.top) * scaleY;
      
      console.log('Coordinate transform: click(' + e.clientX + ',' + e.clientY + ') -> canvas(' + Math.round(x) + ',' + Math.round(y) + ') | Canvas: ' + canvas.width + 'x' + canvas.height + ' Display: ' + Math.round(rect.width) + 'x' + Math.round(rect.height) + ' Scale: ' + scaleX.toFixed(2) + 'x' + scaleY.toFixed(2));
      
      return { x: Math.round(x), y: Math.round(y) };
    }
    
    // Mouse control
    document.getElementById('canvas').addEventListener('click', (e) => {
      if (ws && ws.readyState === WebSocket.OPEN) {
        const coords = getScaledCoords(e);
        
        // Visual feedback for debugging
        if (window.DEBUG_COORDINATES) {
          const canvas = document.getElementById('canvas');
          const ctx = canvas.getContext('2d');
          
          // Draw a red circle at the click location
          ctx.fillStyle = 'red';
          ctx.beginPath();
          ctx.arc(coords.x, coords.y, 5, 0, 2 * Math.PI);
          ctx.fill();
          
          // Draw coordinates text
          ctx.fillStyle = 'white';
          ctx.font = '12px monospace';
          ctx.fillText('(' + coords.x + ', ' + coords.y + ')', coords.x + 10, coords.y - 10);
          
          // Log detailed coordinate info
          console.log('=== CLICK DEBUG ===');
          console.log('Browser click:', e.clientX, e.clientY);
          console.log('Canvas coords:', coords.x, coords.y);
          console.log('Canvas size:', canvas.width, 'x', canvas.height);
          console.log('Display size:', canvas.style.width, 'x', canvas.style.height);
          console.log('==================');
        }
        
        ws.send(JSON.stringify({
          type: 'input',
          data: { 
            type: 'click', 
            x: coords.x, 
            y: coords.y,
            canvasWidth: document.getElementById('canvas').width,
            canvasHeight: document.getElementById('canvas').height
          }
        }));
      }
    });
    
    // Keyboard control
    document.addEventListener('keydown', (e) => {
      if (ws && ws.readyState === WebSocket.OPEN && document.getElementById('viewer').style.display !== 'none') {
        e.preventDefault();
        
        ws.send(JSON.stringify({
          type: 'input',
          data: { 
            type: 'keydown', 
            key: e.key,
            ctrlKey: e.ctrlKey,
            metaKey: e.metaKey,
            altKey: e.altKey
          }
        }));
      }
    });
    
    // Load apps when page loads
    window.onload = loadApps;
  </script>
</body>
</html>
  `);
});

app.listen(port, '0.0.0.0', () => {
  const platform = os.platform();
  const method = platform === 'darwin' ? 'ScreenCaptureKit HTTP API' : 'import + xdotool';
  
  console.log(`
╔════════════════════════════════════════╗
║      Remote Desktop VNC v2 (HTTP)     ║
╠════════════════════════════════════════╣
║  URL: http://0.0.0.0:${port}               ║
║  Platform: ${platform}                    ║
║  Method: ${method}    ║
║  Native API: http://0.0.0.0:8080       ║
║  Display: ${process.env.DISPLAY || 'default'}              ║
╚════════════════════════════════════════╝
  `);
});
