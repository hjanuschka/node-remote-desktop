const express = require('express');
const { exec, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { v4: uuidv4 } = require('uuid');
const WebSocket = require('ws');
const cors = require('cors');

const app = express();
const port = 3000;

app.use(cors());

const wss = new WebSocket.Server({ port: 8080 });

class SimpleVNC {
  constructor(ws) {
    this.ws = ws;
    this.intervalId = null;
  }

  start() {
    console.log('Starting simple screenshot streaming...');
    
    // Take screenshots at 2 FPS and stream them
    this.intervalId = setInterval(async () => {
      try {
        const filename = `/tmp/vnc_${Date.now()}.jpg`;
        
        // Cross-platform screenshot
        const screenshotCmd = this.getScreenshotCommand(filename);
        exec(screenshotCmd, async (err) => {
          if (!err && fs.existsSync(filename)) {
            try {
              const imageData = fs.readFileSync(filename);
              
              if (this.ws.readyState === WebSocket.OPEN) {
                // Send as binary JPEG data
                this.ws.send(imageData);
              }
              
              fs.unlinkSync(filename);
            } catch (e) {
              console.error('File error:', e);
            }
          }
        });
      } catch (error) {
        console.error('Screenshot error:', error);
      }
    }, 500); // 2 FPS
  }

  stop() {
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
      return `DISPLAY=${display} import -window root "${filename}"`;
    } else {
      throw new Error(`Unsupported platform: ${platform}`);
    }
  }

  handleInput(data) {
    try {
      if (data.type === 'mousedown') {
        const clickCmd = this.getClickCommand(data.x, data.y);
        exec(clickCmd);
      } else if (data.type === 'keydown') {
        const keyCmd = this.getKeyCommand(data);
        if (keyCmd) exec(keyCmd);
      }
    } catch (error) {
      console.error('Input error:', error);
    }
  }

  getClickCommand(x, y) {
    const platform = os.platform();
    const roundX = Math.round(x);
    const roundY = Math.round(y);
    
    if (platform === 'darwin') {
      return `cliclick c:${roundX},${roundY}`;
    } else if (platform === 'linux') {
      const display = process.env.DISPLAY || ':20.0';
      return `DISPLAY=${display} xdotool mousemove ${roundX} ${roundY} click 1`;
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
  <canvas id="canvas" style="width:100%; height:100vh; cursor:crosshair;"></canvas>
  
  <script>
    let ws = null;
    const canvas = document.getElementById('canvas');
    const ctx = canvas.getContext('2d');
    let frameCount = 0;
    let lastSecond = Date.now();
    
    function connect() {
      ws = new WebSocket('ws://localhost:8080');
      ws.binaryType = 'arraybuffer';
      
      ws.onopen = () => {
        ws.send(JSON.stringify({ type: 'start' }));
        document.getElementById('status').textContent = 'Connected';
      };
      
      ws.onmessage = (event) => {
        if (typeof event.data === 'string') {
          console.log('Control:', JSON.parse(event.data));
        } else {
          // Display JPEG image on canvas
          const blob = new Blob([event.data], {type: 'image/jpeg'});
          const img = new Image();
          img.onload = () => {
            canvas.width = img.width;
            canvas.height = img.height;
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
    
    canvas.addEventListener('click', (e) => {
      if (ws && ws.readyState === WebSocket.OPEN) {
        const rect = canvas.getBoundingClientRect();
        const x = (e.clientX - rect.left) * (canvas.width / rect.width);
        const y = (e.clientY - rect.top) * (canvas.height / rect.height);
        
        ws.send(JSON.stringify({
          type: 'input',
          data: { type: 'mousedown', x: x, y: y }
        }));
      }
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