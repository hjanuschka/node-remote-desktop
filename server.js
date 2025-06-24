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

function startServerScreenCapture() {
  console.log('🚀 Starting HTTP API screen capture server...');
  
  if (platform === 'darwin') {
    // Auto-recompile native binaries on startup
    const nativeDir = path.join(__dirname, 'native', 'osx');
    console.log('🔨 Recompiling native binaries...');
    
    // Compile main capture binary
    exec(`cd "${nativeDir}" && clang -o screencap7 screencap7_clean.m -framework Foundation -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework ImageIO -framework UniformTypeIdentifiers -framework CoreGraphics -framework AppKit`, (error) => {
      if (error) {
        console.error('❌ Failed to compile screencap7:', error.message);
      } else {
        console.log('✅ screencap7 compiled successfully');
      }
    });
    
    // Compile window listing tool
    exec(`cd "${nativeDir}" && clang -o list_windows_cg list_windows_cg.m -framework Foundation -framework CoreGraphics`, (error) => {
      if (error) {
        console.error('❌ Failed to compile list_windows_cg:', error.message);
      } else {
        console.log('✅ list_windows_cg compiled successfully');
      }
    });
    
    // Use our native ScreenCaptureKit HTTP server!
    const binaryPath = path.join(__dirname, 'native', 'osx', 'screencap7');
    
    if (!fs.existsSync(binaryPath)) {
      console.error('❌ Native screencap7 binary not found! Run: cd native/osx && clang -o screencap7 screencap7_clean.m');
      return;
    }
    
    console.log('🔥 Starting native macOS ScreenCaptureKit HTTP server...');
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
      
      console.log('✅ Native macOS HTTP server started on port 8080!');
    }
    
  } else if (platform === 'linux') {
    const display = process.env.DISPLAY || ':20.0';
    ffmpegProcess = spawn('ffmpeg', [
      '-f', 'x11grab',
      '-video_size', '1600x900',
      '-framerate', '25',
      '-i', display,
      '-q:v', '4',
      '-f', 'image2pipe',
      '-vcodec', 'mjpeg',
      'pipe:1'
    ]);
    
    if (ffmpegProcess) {
      ffmpegProcess.stderr.on('data', (data) => {
        console.log('FFmpeg:', data.toString());
      });
      
      ffmpegProcess.on('close', (code) => {
        console.log('FFmpeg process closed:', code);
      });
      
      console.log('✅ Linux FFmpeg started!');
    }
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
    const response = await fetch('http://localhost:8080/capture-window', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ cgWindowID: parseInt(cgWindowID) })
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

// Endpoint to get window list using standalone Objective-C tool (Carmack approach: use what works!)
app.get('/windows', (req, res) => {
  const { exec } = require('child_process');
  const path = require('path');
  
  const toolPath = path.join(__dirname, 'native', 'osx', 'list_windows_cg');
  
  exec(toolPath, (error, stdout, stderr) => {
    if (error) {
      console.error('Window list tool error:', error);
      res.status(500).json({ error: 'Failed to get windows' });
      return;
    }
    
    try {
      const windows = JSON.parse(stdout);
      res.json(windows);
    } catch (parseError) {
      console.error('Window list parse error:', parseError);
      res.status(500).json({ error: 'Invalid window list data' });
    }
  });
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
    const response = await fetch('http://localhost:8080/capture-window', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ cgWindowID: parseInt(cgWindowID) })
    });
    
    if (response.ok) {
      const result = await response.json();
      console.log('✅ Successfully switched to window:', result);
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

const wss = new WebSocket.Server({ port: 9090 });

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
        const response = await fetch('http://localhost:8080/frame');
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

async function sendClickToNativeBinary(x, y, canvasWidth, canvasHeight) {
  const platform = os.platform();
  
  let scaledX = x;
  let scaledY = y;
  
  if (platform === 'darwin' && canvasWidth && canvasHeight) {
    // Use actual canvas dimensions from browser for precise scaling
    const actualDisplayWidth = 3840;
    const actualDisplayHeight = 1620;
    
    // Scale coordinates from canvas to actual display
    scaledX = Math.round((x / canvasWidth) * actualDisplayWidth);
    scaledY = Math.round((y / canvasHeight) * actualDisplayHeight);
    
    console.log(`Precise scaling: ${x},${y} (canvas ${canvasWidth}x${canvasHeight}) -> ${scaledX},${scaledY} (display ${actualDisplayWidth}x${actualDisplayHeight})`);
    
    // Send click command to HTTP API
    try {
      const response = await fetch('http://localhost:8080/click', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ x: scaledX, y: scaledY })
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
    // Send key command to HTTP API
    try {
      const response = await fetch('http://localhost:8080/key', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ key: data.key })
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

// Route for server machine - auto-shares screen
app.get('/server', (req, res) => {
  res.send(`
<!DOCTYPE html>
<html>
<head><title>Server - Auto Share Screen</title></head>
<body style="margin:0; background:#000;">
  <div style="position:absolute; top:10px; left:10px; color:#fff; font-family:monospace; z-index:100;">
    <div id="status">SERVER MODE - Auto-sharing screen</div>
    <div id="info">Waiting for connections...</div>
    <button onclick="stopSharing()" id="stopBtn" style="display:none;">Stop Sharing</button>
  </div>
  <div style="display:flex; justify-content:center; align-items:center; width:100%; height:100vh;">
    <video id="video" autoplay muted style="max-width:100%; max-height:90vh; border:1px solid #333;"></video>
  </div>
  
  <script>
    let ws = null;
    let pc = null;
    let localStream = null;
    const video = document.getElementById('video');
    
    // Auto-start screen sharing when page loads
    window.onload = async () => {
      await startServerSharing();
    };
    
    async function startServerSharing() {
      try {
        // Get screen stream
        localStream = await navigator.mediaDevices.getDisplayMedia({
          video: { width: 1920, height: 1080, frameRate: 30 },
          audio: false
        });
        
        video.srcObject = localStream;
        document.getElementById('status').textContent = 'SERVER - Sharing screen';
        document.getElementById('info').textContent = 'Screen is being shared. Clients can connect.';
        document.getElementById('stopBtn').style.display = 'inline';
        
        // Connect to signaling server
        ws = new WebSocket('ws://localhost:9090');
        
        ws.onopen = () => {
          console.log('Server connected to signaling');
          ws.send(JSON.stringify({ type: 'server-ready' }));
        };
        
        ws.onmessage = async (event) => {
          const data = JSON.parse(event.data);
          
          if (data.type === 'webrtc-offer') {
            await handleClientOffer(data.offer);
          } else if (data.type === 'webrtc-ice') {
            await pc.addIceCandidate(data.candidate);
          }
        };
        
      } catch (error) {
        console.error('Error starting server sharing:', error);
        document.getElementById('status').textContent = 'ERROR - Could not share screen';
        document.getElementById('info').textContent = error.message;
      }
    }
    
    async function handleClientOffer(offer) {
      // Create new peer connection for this client
      pc = new RTCPeerConnection({
        iceServers: [{ urls: 'stun:stun.l.google.com:19302' }]
      });
      
      // Add our screen stream
      localStream.getTracks().forEach(track => {
        pc.addTrack(track, localStream);
      });
      
      // Handle ICE candidates
      pc.onicecandidate = (event) => {
        if (event.candidate) {
          ws.send(JSON.stringify({
            type: 'webrtc-ice',
            candidate: event.candidate
          }));
        }
      };
      
      // Set remote description and create answer
      await pc.setRemoteDescription(offer);
      const answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      
      ws.send(JSON.stringify({
        type: 'webrtc-answer',
        answer: answer
      }));
      
      console.log('Connected to client');
    }
    
    function stopSharing() {
      if (localStream) localStream.getTracks().forEach(track => track.stop());
      if (pc) pc.close();
      if (ws) ws.close();
      video.srcObject = null;
      document.getElementById('status').textContent = 'STOPPED';
      document.getElementById('info').textContent = 'Screen sharing stopped';
      document.getElementById('stopBtn').style.display = 'none';
    }
  </script>
</body>
</html>
  `);
});

// Route for clients - shows grid to select application
app.get('/', (req, res) => {
  res.send(`
<!DOCTYPE html>
<html>
<head>
  <title>Remote Desktop - Select Application</title>
  <style>
    body { margin: 0; padding: 20px; background: #1a1a1a; color: white; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
    .header { text-align: center; margin-bottom: 30px; }
    .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 20px; max-width: 1400px; margin: 0 auto; }
    .app-card { 
      background: #2a2a2a; border-radius: 12px; padding: 15px; cursor: pointer; 
      transition: all 0.2s ease; border: 2px solid transparent;
    }
    .app-card:hover { background: #3a3a3a; border-color: #007acc; transform: translateY(-2px); }
    .app-card.selected { border-color: #00ff00; background: #1a3a1a; }
    .app-name { font-weight: bold; margin-bottom: 10px; font-size: 16px; }
    .app-type { font-size: 12px; color: #888; margin-bottom: 10px; text-transform: uppercase; }
    .thumbnail { width: 100%; height: 180px; background: #000; border-radius: 8px; object-fit: contain; }
    .no-thumbnail { 
      width: 100%; height: 180px; background: #333; border-radius: 8px; 
      display: flex; align-items: center; justify-content: center; color: #666; font-size: 14px;
    }
    .status { text-align: center; margin-top: 20px; padding: 10px; background: #2a2a2a; border-radius: 8px; }
    .viewer { display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: #000; z-index: 1000; }
    .viewer-header { 
      position: absolute; top: 10px; left: 10px; right: 10px; z-index: 1001; 
      display: flex; justify-content: space-between; align-items: center; color: white; 
    }
    .viewer-info { font-family: monospace; font-size: 14px; }
    .back-btn { 
      background: #ff4444; color: white; border: none; padding: 8px 16px; 
      border-radius: 6px; cursor: pointer; font-weight: bold; 
    }
    .back-btn:hover { background: #ff6666; }
    .viewer-canvas { cursor: crosshair; }
  </style>
</head>
<body>
  <div id="grid-view">
    <div class="header">
      <h1>🖥️ Remote Desktop - Select Application</h1>
      <p>Choose an application or desktop to control remotely</p>
    </div>
    <div class="grid" id="apps-grid"></div>
    <div class="status" id="status">Loading applications...</div>
  </div>

  <div id="viewer" class="viewer">
    <div class="viewer-header">
      <div class="viewer-info">
        <div id="viewer-app-name">Desktop</div>
        <div id="viewer-fps">FPS: 0</div>
        <div>Click on screen to control • Use keyboard for typing</div>
      </div>
      <button class="back-btn" onclick="showGrid()">← Back to Grid</button>
    </div>
    <div style="display:flex; justify-content:center; align-items:center; width:100%; height:100vh;">
      <canvas id="canvas" class="viewer-canvas"></canvas>
    </div>
  </div>

  <script>
    let ws = null;
    let apps = [];
    let selectedApp = null;
    let frameCount = 0;
    let lastSecond = Date.now();
    
    // Load applications grid using only Swift script (bypass problematic /apps endpoint)
    async function loadApps() {
      try {
        // Get windows from Swift script only
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
            name: \`\${window.app}: \${window.title}\`,
            type: 'window',
            cgWindowID: window.cgWindowID,
            title: window.title,
            app: window.app,
            position: window.position,
            size: window.size
          });
        });
        
        renderGrid();
        document.getElementById('status').textContent = \`Found \${apps.length} items (\${apps.length - 1} windows + desktop)\`;
      } catch (error) {
        document.getElementById('status').textContent = 'Error: Cannot load windows';
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
        
        let typeClass, subtitle;
        if (app.type === 'desktop') {
          typeClass = '🖥️';
          subtitle = 'Full Desktop';
        } else if (app.type === 'window') {
          typeClass = '🪟';
          subtitle = \`\${app.size.width}×\${app.size.height} at (\${app.position.x}, \${app.position.y})\`;
        } else {
          typeClass = '📱';
          subtitle = 'Application';
        }
        
        card.innerHTML = \`
          <div class="app-type">\${typeClass} \${subtitle}</div>
          <div class="app-name">\${app.name}</div>
          <div class="no-thumbnail">Click to capture this \${app.type === 'window' ? 'window' : 'screen'}</div>
        \`;
        
        grid.appendChild(card);
      });
    }
    
    async function selectApp(app) {
      selectedApp = app;
      document.getElementById('viewer-app-name').textContent = \`Controlling: \${app.name}\`;
      
      // Start capture for this app
      try {
        if (app.type === 'desktop') {
          // For desktop, use the native HTTP API
          const response = await fetch('http://localhost:8080/capture', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ type: 0, index: 0 })
          });
          
          if (response.ok) {
            showViewer();
            connectWebSocket();
          } else {
            alert('Failed to start desktop capture');
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
            showViewer();
            connectWebSocket();
          } else {
            alert('Failed to switch to window');
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
      
      // Refresh the grid
      loadApps();
    }
    
    function showViewer() {
      document.getElementById('grid-view').style.display = 'none';
      document.getElementById('viewer').style.display = 'block';
    }
    
    function connectWebSocket() {
      ws = new WebSocket('ws://localhost:9090');
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
        // Auto-size canvas to fit screen
        const maxWidth = window.innerWidth - 40;
        const maxHeight = window.innerHeight - 80;
        const aspectRatio = img.width / img.height;
        
        let displayWidth = img.width;
        let displayHeight = img.height;
        
        if (displayWidth > maxWidth) {
          displayWidth = maxWidth;
          displayHeight = displayWidth / aspectRatio;
        }
        
        if (displayHeight > maxHeight) {
          displayHeight = maxHeight;
          displayWidth = displayHeight * aspectRatio;
        }
        
        canvas.width = img.width;
        canvas.height = img.height;
        canvas.style.width = displayWidth + 'px';
        canvas.style.height = displayHeight + 'px';
        ctx.drawImage(img, 0, 0);
        updateFPS();
      };
      
      img.src = URL.createObjectURL(blob);
    }
    
    function updateFPS() {
      frameCount++;
      const now = Date.now();
      if (now - lastSecond >= 1000) {
        document.getElementById('viewer-fps').textContent = \`FPS: \${frameCount}\`;
        frameCount = 0;
        lastSecond = now;
      }
    }
    
    function getScaledCoords(e) {
      const canvas = document.getElementById('canvas');
      const rect = canvas.getBoundingClientRect();
      const scaleX = canvas.width / rect.width;
      const scaleY = canvas.height / rect.height;
      const x = (e.clientX - rect.left) * scaleX;
      const y = (e.clientY - rect.top) * scaleY;
      return { x: Math.round(x), y: Math.round(y) };
    }
    
    // Mouse control
    document.getElementById('canvas').addEventListener('click', (e) => {
      if (ws && ws.readyState === WebSocket.OPEN) {
        const coords = getScaledCoords(e);
        
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

app.listen(port, () => {
  const platform = os.platform();
  const method = platform === 'darwin' ? 'ScreenCaptureKit HTTP API' : 'import + xdotool';
  
  console.log(`
╔════════════════════════════════════════╗
║      Remote Desktop VNC v2 (HTTP)     ║
╠════════════════════════════════════════╣
║  URL: http://localhost:${port}             ║
║  Platform: ${platform}                    ║
║  Method: ${method}    ║
║  Native API: http://localhost:8080     ║
║  Display: ${process.env.DISPLAY || 'default'}              ║
╚════════════════════════════════════════╝
  `);
});
