# WebRTC Implementation Guide

## 🚀 Quick Start - Implementing WebRTC for Butter-Smooth Experience

### Current vs Target Performance

| Aspect | Current (MJPEG/WS) | Target (WebRTC) | Improvement |
|--------|-------------------|------------------|-------------|
| **Latency** | 200-500ms | 20-50ms | **10x faster** |
| **Bandwidth** | 50-100 Mbps | 5-20 Mbps | **5x less** |
| **Quality** | Fixed | Adaptive | **Dynamic** |
| **Hardware** | CPU only | GPU accelerated | **Efficient** |

### Phase 1: Basic WebRTC Setup (1-2 weeks)

#### 1.1 Install WebRTC Signaling
```bash
npm install ws socket.io express
```

#### 1.2 Add WebRTC Routes to server.js
```javascript
// Add after existing routes in server.js
app.post('/webrtc/offer', async (req, res) => {
  const { offer, windowId } = req.body;
  
  // Store offer for this session
  currentWebRTCOffer = offer;
  currentWindowForWebRTC = windowId;
  
  res.json({ 
    status: 'offer_received',
    message: 'Connect via WebRTC for ultra-low latency'
  });
});

app.get('/webrtc/stream', (req, res) => {
  // Serve WebRTC client page
  res.sendFile(path.join(__dirname, 'webrtc-client.html'));
});
```

#### 1.3 Replace Current Video Display
```javascript
// In the main client page, add WebRTC option
function startWebRTCMode() {
  if (navigator.mediaDevices && navigator.mediaDevices.getDisplayMedia) {
    window.location.href = '/webrtc/stream';
  } else {
    alert('WebRTC not supported - falling back to WebSocket mode');
  }
}
```

### Phase 2: Hardware Acceleration (2-3 weeks)

#### 2.1 Compile WebRTC Encoder
```bash
cd native/osx
clang -o webrtc_encoder webrtc_encoder.m -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework Foundation
```

#### 2.2 Integrate with ScreenCaptureKit
Add to `screencap7_clean.m`:
```objective-c
#import "webrtc_encoder.h"

@property (nonatomic, strong) WebRTCEncoder *videoEncoder;

// In setupCapture method, add:
if (useWebRTCMode) {
    self.videoEncoder = [[WebRTCEncoder alloc] 
        initWithCodec:kCMVideoCodecType_H264 
               width:config.width 
              height:config.height 
             bitrate:10000000  // 10 Mbps
           framerate:60];
}

// In frame processing:
if (self.videoEncoder) {
    NSData *h264Data = [self.videoEncoder encodeFrame:imageBuffer];
    // Send H264 data via WebRTC data channel or HTTP stream
}
```

### Phase 3: Advanced Optimizations (4+ weeks)

#### 3.1 Adaptive Bitrate Implementation
```javascript
// Monitor network conditions
function monitorNetworkQuality() {
  setInterval(async () => {
    const stats = await peerConnection.getStats();
    stats.forEach(report => {
      if (report.type === 'outbound-rtp') {
        const packetLoss = report.packetsLost / report.packetsSent;
        const jitter = report.jitter;
        
        adjustVideoQuality(packetLoss, jitter);
      }
    });
  }, 1000);
}

function adjustVideoQuality(packetLoss, jitter) {
  const senders = peerConnection.getSenders();
  const videoSender = senders.find(s => s.track?.kind === 'video');
  
  if (packetLoss > 0.02) {
    // Reduce quality
    updateNativeEncoder('bitrate', currentBitrate * 0.8);
  } else if (packetLoss < 0.005) {
    // Increase quality
    updateNativeEncoder('bitrate', currentBitrate * 1.1);
  }
}
```

#### 3.2 Content-Aware Encoding
```objective-c
// Add motion detection to WebRTCEncoder
- (BOOL)detectHighMotion:(CVPixelBufferRef)currentFrame 
            previousFrame:(CVPixelBufferRef)previousFrame {
    
    // Compare frames using Metal Performance Shaders
    // Return YES if high motion detected
    
    // Adjust encoding parameters based on motion
    if (highMotion) {
        [self updateFramerate:60];  // Higher FPS for motion
        [self updateBitrate:15000000];  // Higher bitrate
    } else {
        [self updateFramerate:30];  // Lower FPS for static content
        [self updateBitrate:8000000];   // Lower bitrate
    }
}
```

### Implementation Steps

#### Step 1: Test Current Performance
```bash
# Run the coordinate test to see current latency
./test-coordinates.sh

# Monitor bandwidth usage
nettop -P -L 1 -x -J bytes_in,bytes_out
```

#### Step 2: Enable WebRTC Client
```html
<!-- Create webrtc-client.html -->
<!DOCTYPE html>
<html>
<head>
    <title>WebRTC Ultra-Low Latency Remote Desktop</title>
</head>
<body>
    <div id="status">Connecting via WebRTC...</div>
    <video id="remoteVideo" autoplay muted playsinline></video>
    
    <script src="webrtc-prototype.js"></script>
    <script>
        async function startWebRTCClient() {
            const client = new WebRTCScreenShare();
            await client.startClient();
            
            // Get offer from server
            const response = await fetch('/webrtc/get-offer');
            const { offer } = await response.json();
            
            if (offer) {
                const answer = await client.handleOffer(offer);
                
                // Send answer back
                await fetch('/webrtc/answer', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ answer })
                });
            }
        }
        
        startWebRTCClient();
    </script>
</body>
</html>
```

#### Step 3: Benchmark Improvements
```javascript
// Add performance monitoring
class PerformanceMonitor {
  constructor() {
    this.startTime = performance.now();
    this.frameCount = 0;
    this.latencySum = 0;
  }
  
  recordFrame(timestamp) {
    this.frameCount++;
    const latency = performance.now() - timestamp;
    this.latencySum += latency;
    
    if (this.frameCount % 60 === 0) {
      const avgLatency = this.latencySum / this.frameCount;
      const fps = this.frameCount / ((performance.now() - this.startTime) / 1000);
      
      console.log(`📊 Performance: ${fps.toFixed(1)} FPS, ${avgLatency.toFixed(1)}ms avg latency`);
    }
  }
}
```

### Expected Results

#### After Phase 1 (Basic WebRTC):
- ✅ **Latency**: 50-100ms (vs 200-500ms)
- ✅ **Bandwidth**: 20-40 Mbps (vs 50-100 Mbps)
- ✅ **Compatibility**: Works on all modern browsers

#### After Phase 2 (Hardware Acceleration):
- ✅ **Latency**: 30-60ms
- ✅ **Bandwidth**: 10-25 Mbps
- ✅ **CPU Usage**: 50% reduction
- ✅ **Quality**: Better compression

#### After Phase 3 (Full Optimization):
- ✅ **Latency**: 20-50ms (butter smooth!)
- ✅ **Bandwidth**: 5-20 Mbps (adaptive)
- ✅ **Quality**: Content-aware optimization
- ✅ **Reliability**: Network resilience

### Troubleshooting

#### Common Issues:
1. **WebRTC not connecting**: Check firewall/NAT settings
2. **High latency**: Ensure hardware acceleration is enabled
3. **Poor quality**: Adjust bitrate based on network conditions
4. **Audio desync**: Use same clock for audio/video encoding

#### Debug Commands:
```bash
# Check hardware acceleration support
system_profiler SPDisplaysDataType | grep -A 5 "Graphics/Displays"

# Monitor video encoding performance
sudo powermetrics -s gpu_power -n 1

# Test WebRTC connectivity
telnet stun.l.google.com 19302
```

### Migration Strategy

1. **Parallel Implementation**: Keep existing WebSocket mode as fallback
2. **Progressive Rollout**: Start with desktop capture, then window capture
3. **Performance Testing**: Benchmark each phase before proceeding
4. **User Choice**: Allow users to select WebRTC vs WebSocket mode

This implementation will transform your screen sharing from "functional" to "butter smooth" professional-grade remote desktop experience! 🚀