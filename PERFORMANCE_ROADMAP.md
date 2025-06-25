# Performance Improvement Roadmap

## 🎯 Goal: Butter-Smooth Remote Desktop Experience

### Current State
- **Protocol**: MJPEG over WebSocket
- **Latency**: 200-500ms
- **Bandwidth**: ~50-100 Mbps (uncompressed)
- **Quality**: Fixed compression
- **Hardware**: CPU-only encoding

### Target State
- **Protocol**: WebRTC P2P + fallback
- **Latency**: <50ms
- **Bandwidth**: 5-20 Mbps (adaptive)
- **Quality**: Dynamic based on content/network
- **Hardware**: GPU-accelerated when available

## Phase 1: WebRTC Implementation 🚀

### 1.1 Core WebRTC Setup
```javascript
// Replace current WebSocket streaming with WebRTC
const peerConnection = new RTCPeerConnection({
  iceServers: [{ urls: 'stun:stun.l.google.com:19302' }]
});

// Add screen capture stream
const stream = await navigator.mediaDevices.getDisplayMedia({
  video: {
    width: { ideal: 1920 },
    height: { ideal: 1080 },
    frameRate: { ideal: 60, max: 60 }
  }
});
```

### 1.2 Hardware-Accelerated Encoding
```objective-c
// In screencap7_clean.m - Add VideoToolbox support
VTCompressionSessionRef compressionSession;
VTCompressionSessionCreate(
    NULL, width, height,
    kCMVideoCodecType_H264,  // or kCMVideoCodecType_HEVC
    NULL, NULL, NULL,
    compressionOutputCallback,
    NULL, &compressionSession
);

// Configure for real-time encoding
VTSessionSetProperty(compressionSession, 
    kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
VTSessionSetProperty(compressionSession,
    kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
```

### 1.3 Signaling Server Enhancement
```javascript
// Add WebRTC signaling to existing HTTP server
app.post('/webrtc/offer', async (req, res) => {
  const { offer } = req.body;
  // Process offer, create answer
  const answer = await createAnswer(offer);
  res.json({ answer });
});

app.post('/webrtc/ice', async (req, res) => {
  const { candidate } = req.body;
  // Handle ICE candidates
  await handleIceCandidate(candidate);
  res.json({ status: 'ok' });
});
```

## Phase 2: Advanced Optimizations 🔧

### 2.1 Codec Selection & Quality
```javascript
// Adaptive codec selection
const codecs = RTCRtpSender.getCapabilities('video').codecs;
const preferredCodecs = [
  'video/AV1',     // Best compression
  'video/VP9',     // Good compression + compatibility
  'video/H264',    // Hardware accelerated
  'video/VP8'      // Fallback
];

// Dynamic quality adjustment
function adjustQuality(networkStats) {
  if (networkStats.packetLoss > 0.02) {
    // Reduce quality
    sender.setParameters({
      encodings: [{
        maxBitrate: currentBitrate * 0.8,
        scaleResolutionDownBy: 1.2
      }]
    });
  }
}
```

### 2.2 Content-Aware Encoding
```javascript
// Detect content type for optimal encoding
function analyzeContent(frame) {
  const motion = detectMotion(frame);
  const complexity = calculateComplexity(frame);
  
  if (motion > 0.5) {
    // High motion: prioritize frame rate
    return { frameRate: 60, bitrate: 'high' };
  } else if (complexity < 0.3) {
    // Simple content: reduce bitrate
    return { frameRate: 30, bitrate: 'low' };
  }
}
```

### 2.3 Input Optimization
```javascript
// Use WebRTC data channels for mouse/keyboard
const dataChannel = peerConnection.createDataChannel('input', {
  ordered: false,     // Allow out-of-order for lower latency
  maxRetransmits: 0   // Don't retransmit old input
});

// Send input with minimal overhead
function sendInput(event) {
  const data = new Uint8Array([
    event.type,  // 1 byte
    event.x >> 8, event.x & 0xFF,  // 2 bytes
    event.y >> 8, event.y & 0xFF,  // 2 bytes
    event.button  // 1 byte
  ]);
  dataChannel.send(data);
}
```

## Phase 3: Platform-Specific Optimizations 🎮

### 3.1 macOS Optimizations
```objective-c
// Use Metal Performance Shaders for preprocessing
id<MTLTexture> texture = [metalDevice newTextureWithDescriptor:textureDesc];
id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];

// Apply real-time filters (denoising, sharpening)
MPSImageGaussianBlur *blur = [[MPSImageGaussianBlur alloc] 
    initWithDevice:metalDevice sigma:0.5];
[blur encodeToCommandBuffer:commandBuffer 
    sourceTexture:sourceTexture 
    destinationTexture:processedTexture];
```

### 3.2 Smart Frame Skipping
```objective-c
// Skip frames when no changes detected
- (BOOL)shouldSkipFrame:(CVPixelBufferRef)currentFrame {
    static CVPixelBufferRef lastFrame = NULL;
    
    CGFloat similarity = [self compareFrames:currentFrame with:lastFrame];
    if (similarity > 0.99) {
        return YES;  // Skip nearly identical frames
    }
    
    CVPixelBufferRelease(lastFrame);
    lastFrame = CVPixelBufferRetain(currentFrame);
    return NO;
}
```

## Phase 4: Network Resilience 🌐

### 4.1 Multi-path Streaming
```javascript
// Use multiple connections for reliability
const connections = [
  createConnection('primary'),
  createConnection('backup')
];

// Switch connections based on quality
function monitorConnections() {
  connections.forEach(conn => {
    conn.getStats().then(stats => {
      if (stats.packetLoss > 0.05) {
        switchToBackup(conn);
      }
    });
  });
}
```

### 4.2 Predictive Buffering
```javascript
// Buffer frames based on network prediction
class AdaptiveBuffer {
  constructor() {
    this.targetLatency = 50; // ms
    this.buffer = [];
  }
  
  addFrame(frame, timestamp) {
    const networkLatency = this.estimateLatency();
    const bufferTime = Math.max(networkLatency * 1.5, this.targetLatency);
    
    this.buffer.push({ frame, timestamp, bufferTime });
    this.processBuffer();
  }
}
```

## Implementation Priority

### Immediate (Week 1-2)
1. ✅ Basic WebRTC peer connection setup
2. ✅ Replace WebSocket with WebRTC video stream  
3. ✅ Implement signaling server

### Short-term (Week 3-4)
1. Hardware-accelerated encoding in native binary
2. Adaptive bitrate based on network conditions
3. Input via WebRTC data channels

### Medium-term (Month 2)
1. Multiple codec support (AV1, VP9, H.264)
2. Content-aware encoding optimization
3. Smart frame skipping and motion detection

### Long-term (Month 3+)
1. Multi-path streaming for reliability
2. Predictive buffering and latency optimization
3. Metal/GPU acceleration for preprocessing

## Expected Performance Gains

| Metric | Current | After WebRTC | After Full Optimization |
|--------|---------|--------------|------------------------|
| Latency | 200-500ms | 50-100ms | 20-50ms |
| Bandwidth | 50-100 Mbps | 10-30 Mbps | 5-20 Mbps |
| Quality | Fixed | Adaptive | Content-aware |
| CPU Usage | High | Medium | Low (GPU accelerated) |
| Frame Rate | 30 FPS | 60 FPS | 60+ FPS |

## Technology Stack

- **WebRTC**: P2P streaming with hardware acceleration
- **VideoToolbox**: macOS hardware encoding (H.264/HEVC)
- **Metal**: GPU preprocessing and effects
- **AV1/VP9**: Next-gen compression for bandwidth efficiency
- **STUN/TURN**: NAT traversal for P2P connections
- **WebCodecs API**: Fine-grained codec control in browser