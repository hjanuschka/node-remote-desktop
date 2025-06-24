const express = require('express');
const { exec, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { v4: uuidv4 } = require('uuid');
const WebSocket = require('ws');
const cors = require('cors');

const app = express();
const port = 3030;

app.use(cors());

const wss = new WebSocket.Server({ port: 9090 });

class SimpleVNC {
  constructor(ws) {
    this.ws = ws;
    this.ffmpegProcess = null;
  }

  start() {
    const platform = os.platform();
    
    if (platform === 'darwin') {
      console.log('Starting macOS fast JPEG streaming...');
      
      // Start ffmpeg to capture screen and output JPEG frames on macOS
      this.ffmpegProcess = spawn('ffmpeg', [
        '-f', 'avfoundation',
        '-framerate', '30',
        '-i', '1:0',  // Screen capture
        '-vf', 'scale=1024:768',
        '-q:v', '3',
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
      if (data.type === 'mousedown') {
        const cmd = this.getMouseCommand('mousedown', data.x, data.y, data.button);
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
        return `cliclick dd:${roundX},${roundY}`;
      } else if (type === 'mousemove') {
        return `cliclick m:${roundX},${roundY}`;
      } else if (type === 'mouseup') {
        return `cliclick du:${roundX},${roundY}`;
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

wss.on('connection', ws => {
  let session = null;
  console.log('Client connected');

  ws.on('message', async message => {
    try {
      const data = JSON.parse(message);

      switch (data.type) {
        case 'start':
          session = new SimpleVNC(ws);
          session.start();
          ws.send(JSON.stringify({ type: 'started' }));
          break;

        case 'input':
          if (session) {
            session.handleInput(data.data);
          }
          break;

        case 'stop':
          if (session) {
            session.stop();
            session = null;
          }
          break;
      }
    } catch (error) {
      console.error('Error:', error);
    }
  });

  ws.on('close', () => {
    if (session) {
      session.stop();
    }
  });
});

app.get('/', (req, res) => {
  res.send(`
<!DOCTYPE html>
<html>
<head><title>Remote Desktop</title></head>
<body style="margin:0; background:#000;">
  <div style="position:absolute; top:10px; left:10px; color:#fff; font-family:monospace; z-index:100;">
    <button onclick="connect()">Connect</button>
    <button onclick="disconnect()">Disconnect</button>
    <div id="status">Disconnected</div>
    <div id="fps">FPS: 0</div>
  </div>
  <div style="display:flex; justify-content:center; align-items:center; width:100%; height:100vh;">
    <canvas id="canvas" style="cursor:crosshair; border:1px solid #333;"></canvas>
  </div>
  
  <script>
    let ws = null;
    const canvas = document.getElementById('canvas');
    const ctx = canvas.getContext('2d');
    let frameCount = 0;
    let lastSecond = Date.now();
    
    function connect() {
      ws = new WebSocket('ws://localhost:9090');
      ws.binaryType = 'arraybuffer';
      
      ws.onopen = () => {
        ws.send(JSON.stringify({ type: 'start' }));
        document.getElementById('status').textContent = 'Connected';
      };
      
      ws.onmessage = (event) => {
        if (typeof event.data === 'string') {
          console.log('Control:', JSON.parse(event.data));
        } else {
          // Display JPEG frame on canvas
          const blob = new Blob([event.data], {type: 'image/jpeg'});
          const img = new Image();
          img.onload = () => {
            // Maintain aspect ratio and fit within viewport
            const maxWidth = window.innerWidth - 20;
            const maxHeight = window.innerHeight - 100;
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
      };
      
      ws.onclose = () => {
        document.getElementById('status').textContent = 'Disconnected';
      };
    }
    
    function updateFPS() {
      frameCount++;
      const now = Date.now();
      if (now - lastSecond >= 1000) {
        document.getElementById('fps').textContent = \`FPS: \${frameCount}\`;
        frameCount = 0;
        lastSecond = now;
      }
    }
    
    function disconnect() {
      if (ws) {
        ws.send(JSON.stringify({ type: 'stop' }));
        ws.close();
      }
    }
    
    let isDragging = false;
    let lastMouseTime = 0;
    
    function getScaledCoords(e) {
      const rect = canvas.getBoundingClientRect();
      const scaleX = canvas.width / rect.width;
      const scaleY = canvas.height / rect.height;
      const x = (e.clientX - rect.left) * scaleX;
      const y = (e.clientY - rect.top) * scaleY;
      
      // Scale back up to original display resolution (1600x1200)
      const screenshotScaleX = 1024 / 1600;
      const screenshotScaleY = 768 / 1200;
      const originalX = x / screenshotScaleX;
      const originalY = y / screenshotScaleY;
      
      return { x: Math.round(originalX), y: Math.round(originalY) };
    }
    
    canvas.addEventListener('mousedown', (e) => {
      if (ws && ws.readyState === WebSocket.OPEN) {
        isDragging = true;
        const coords = getScaledCoords(e);
        ws.send(JSON.stringify({
          type: 'input',
          data: { type: 'mousedown', x: coords.x, y: coords.y, button: e.button }
        }));
      }
    });
    
    canvas.addEventListener('mousemove', (e) => {
      if (ws && ws.readyState === WebSocket.OPEN && isDragging) {
        const now = Date.now();
        // Throttle mouse move events to prevent flooding
        if (now - lastMouseTime > 16) { // ~60 FPS
          const coords = getScaledCoords(e);
          ws.send(JSON.stringify({
            type: 'input',
            data: { type: 'mousemove', x: coords.x, y: coords.y }
          }));
          lastMouseTime = now;
        }
      }
    });
    
    canvas.addEventListener('mouseup', (e) => {
      if (ws && ws.readyState === WebSocket.OPEN) {
        isDragging = false;
        const coords = getScaledCoords(e);
        ws.send(JSON.stringify({
          type: 'input',
          data: { type: 'mouseup', x: coords.x, y: coords.y, button: e.button }
        }));
      }
    });
    
    // Prevent context menu
    canvas.addEventListener('contextmenu', (e) => {
      e.preventDefault();
    });
    
    // Keyboard support
    document.addEventListener('keydown', (e) => {
      if (ws && ws.readyState === WebSocket.OPEN && 
          document.getElementById('status').textContent === 'Connected') {
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
  </script>
</body>
</html>
  `);
});

app.listen(port, () => {
  const platform = os.platform();
  const method = platform === 'darwin' ? 'screencapture + cliclick' : 'import + xdotool';
  
  console.log(`
╔════════════════════════════════════════╗
║          Remote Desktop VNC            ║
╠════════════════════════════════════════╣
║  URL: http://localhost:${port}             ║
║  Platform: ${platform}                    ║
║  Method: ${method}        ║
║  Display: ${process.env.DISPLAY || 'default'}              ║
╚════════════════════════════════════════╝
  `);
});
