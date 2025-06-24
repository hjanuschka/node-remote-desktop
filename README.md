# Node Remote Desktop

A WebRTC-based remote desktop application that allows you to view and control windows on your Linux/macOS desktop through a web browser.

## Features

- List all open windows on your desktop
- Take screenshots of individual windows
- Real-time video streaming via WebRTC
- Remote mouse and keyboard control
- Cross-platform support (Linux and macOS)

## Prerequisites

### System Dependencies

#### Linux
```bash
sudo apt-get install wmctrl imagemagick xdotool xvfb ffmpeg
```

#### macOS
```bash
brew install ffmpeg
brew install cliclick
```

### Node.js
- Node.js 14+ required
- npm or yarn

## Installation

1. Clone this repository or create the files as shown above

2. Install Node.js dependencies:
```bash
npm install
```

3. Create a screenshots directory:
```bash
mkdir screenshots
```

## Usage

1. Start the server:
```bash
npm start
```

2. Open your browser and navigate to:
```
http://localhost:3000
```

3. Click "Refresh Windows" to see available windows

4. Click "Connect" on any window to start remote control

5. Use your mouse and keyboard to control the remote window

## How It Works

1. **Window Detection**: Uses `wmctrl` (Linux) or AppleScript (macOS) to list open windows
2. **Screenshots**: Uses `import` (Linux) or `screencapture` (macOS) to capture window images
3. **Video Streaming**: FFmpeg captures the window content and streams it via WebRTC
4. **Remote Control**: Mouse and keyboard events are sent via WebSocket and executed using `xdotool` (Linux) or `cliclick` (macOS)

## Security Considerations

⚠️ **WARNING**: This application provides full control over your desktop. Use with caution!

- Only run on trusted networks
- Consider adding authentication
- Use HTTPS in production
- Restrict access via firewall rules

## Troubleshooting

### Linux

If you get "wmctrl not found" error:
```bash
sudo apt-get install wmctrl
```

If FFmpeg fails to capture:
- Make sure you have X11 running
- Check `$DISPLAY` environment variable
- Try running with `xvfb-run` for headless environments

### macOS

If window listing fails:
- Grant Terminal/IDE accessibility permissions in System Preferences
- Some windows may not be detectable due to macOS security restrictions

### WebRTC Connection Issues

- Check firewall settings
- Ensure ports 3000 and 8080 are accessible
- Try using a STUN server if behind NAT

## Development

To run in development mode with auto-reload:
```bash
npm install -g nodemon
npm run dev
```

## Limitations

- Window capture on macOS is limited due to security restrictions
- Performance depends on network bandwidth and latency
- Some special keys may not work correctly
- Full-screen applications may not be captured properly

## Future Improvements

- Audio streaming support
- Multi-monitor support
- Session recording
- File transfer capabilities
- Better compression algorithms
- Mobile client support

## License

MIT