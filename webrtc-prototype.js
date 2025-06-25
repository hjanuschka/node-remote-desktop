// WebRTC Screen Sharing Prototype
// This replaces the current MJPEG/WebSocket approach

class WebRTCScreenShare {
  constructor() {
    this.peerConnection = null;
    this.dataChannel = null;
    this.stream = null;
    this.isServer = false;
  }

  // Server-side: Start screen capture and offer to clients
  async startServer() {
    this.isServer = true;
    
    // Create peer connection with optimal settings
    this.peerConnection = new RTCPeerConnection({
      iceServers: [
        { urls: 'stun:stun.l.google.com:19302' },
        { urls: 'stun:stun1.l.google.com:19302' }
      ],
      iceCandidatePoolSize: 10
    });

    // Create data channel for low-latency input
    this.dataChannel = this.peerConnection.createDataChannel('input', {
      ordered: false,        // Allow out-of-order delivery
      maxRetransmits: 0,     // Don't retransmit old input
      maxPacketLifeTime: 100 // Drop packets older than 100ms
    });

    this.setupDataChannel();

    // Get screen capture stream with optimal settings
    try {
      this.stream = await navigator.mediaDevices.getDisplayMedia({
        video: {
          width: { ideal: 1920, max: 3840 },
          height: { ideal: 1080, max: 2160 },
          frameRate: { ideal: 60, max: 120 },
          cursor: 'always'
        },
        audio: true // Include system audio
      });

      // Add stream to peer connection
      this.stream.getTracks().forEach(track => {
        this.peerConnection.addTrack(track, this.stream);
      });

      // Optimize video encoding
      await this.optimizeVideoEncoding();

    } catch (error) {
      console.error('Failed to get display media:', error);
      throw error;
    }

    return this.createOffer();
  }

  // Client-side: Connect to server stream
  async startClient() {
    this.isServer = false;
    
    this.peerConnection = new RTCPeerConnection({
      iceServers: [
        { urls: 'stun:stun.l.google.com:19302' },
        { urls: 'stun:stun1.l.google.com:19302' }
      ]
    });

    // Handle incoming stream
    this.peerConnection.ontrack = (event) => {
      const [stream] = event.streams;
      this.displayStream(stream);
    };

    // Handle data channel for input
    this.peerConnection.ondatachannel = (event) => {
      this.dataChannel = event.channel;
      this.setupDataChannel();
    };
  }

  async optimizeVideoEncoding() {
    const senders = this.peerConnection.getSenders();
    const videoSender = senders.find(sender => 
      sender.track && sender.track.kind === 'video'
    );

    if (videoSender) {
      const params = videoSender.getParameters();
      
      // Configure encoding parameters for optimal quality/performance
      if (params.encodings && params.encodings.length > 0) {
        params.encodings[0] = {
          ...params.encodings[0],
          maxBitrate: 10000000,      // 10 Mbps max
          maxFramerate: 60,          // 60 FPS max
          scaleResolutionDownBy: 1,  // No downscaling initially
          priority: 'high',          // High priority for video
          networkPriority: 'high'
        };

        await videoSender.setParameters(params);
      }

      // Monitor stats and adjust dynamically
      this.monitorConnectionStats();
    }
  }

  monitorConnectionStats() {
    setInterval(async () => {
      const stats = await this.peerConnection.getStats();
      
      stats.forEach(report => {
        if (report.type === 'outbound-rtp' && report.mediaType === 'video') {
          const packetLoss = report.packetsLost / (report.packetsSent || 1);
          const bitrate = report.bytesSent * 8 / report.timestamp * 1000;
          
          console.log(`📊 Video Stats: Bitrate: ${(bitrate/1000000).toFixed(1)}Mbps, Loss: ${(packetLoss*100).toFixed(2)}%`);
          
          // Adaptive bitrate based on packet loss
          this.adjustQuality(packetLoss, bitrate);
        }
      });
    }, 2000);
  }

  async adjustQuality(packetLoss, currentBitrate) {
    const senders = this.peerConnection.getSenders();
    const videoSender = senders.find(s => s.track && s.track.kind === 'video');
    
    if (videoSender) {
      const params = videoSender.getParameters();
      
      if (packetLoss > 0.02) { // >2% packet loss
        // Reduce quality
        params.encodings[0].maxBitrate = Math.max(currentBitrate * 0.8, 1000000);
        params.encodings[0].scaleResolutionDownBy = Math.min(
          (params.encodings[0].scaleResolutionDownBy || 1) * 1.2, 4
        );
        console.log('📉 Reducing quality due to packet loss');
      } else if (packetLoss < 0.005) { // <0.5% packet loss
        // Increase quality
        params.encodings[0].maxBitrate = Math.min(currentBitrate * 1.1, 15000000);
        params.encodings[0].scaleResolutionDownBy = Math.max(
          (params.encodings[0].scaleResolutionDownBy || 1) * 0.9, 1
        );
        console.log('📈 Increasing quality - connection stable');
      }
      
      await videoSender.setParameters(params);
    }
  }

  setupDataChannel() {
    this.dataChannel.onopen = () => {
      console.log('✅ Input data channel opened');
    };

    this.dataChannel.onmessage = (event) => {
      if (this.isServer) {
        this.handleRemoteInput(event.data);
      }
    };
  }

  // Send input events with minimal latency
  sendInput(type, x, y, button = 0, key = '') {
    if (this.dataChannel && this.dataChannel.readyState === 'open') {
      const data = {
        type,
        x: Math.round(x),
        y: Math.round(y),
        button,
        key,
        timestamp: performance.now()
      };
      
      // Use binary encoding for minimal overhead
      const buffer = this.encodeInputBinary(data);
      this.dataChannel.send(buffer);
    }
  }

  encodeInputBinary(data) {
    const buffer = new ArrayBuffer(16);
    const view = new DataView(buffer);
    
    view.setUint8(0, this.getInputTypeCode(data.type));
    view.setUint16(1, data.x, true);
    view.setUint16(3, data.y, true);
    view.setUint8(5, data.button);
    view.setFloat64(6, data.timestamp, true);
    
    // For keys, we'd need additional encoding
    return buffer;
  }

  getInputTypeCode(type) {
    const codes = {
      'mousedown': 1,
      'mouseup': 2,
      'mousemove': 3,
      'click': 4,
      'keydown': 5,
      'keyup': 6
    };
    return codes[type] || 0;
  }

  handleRemoteInput(buffer) {
    const view = new DataView(buffer);
    const type = this.getInputTypeFromCode(view.getUint8(0));
    const x = view.getUint16(1, true);
    const y = view.getUint16(3, true);
    const button = view.getUint8(5);
    const timestamp = view.getFloat64(6, true);
    
    const latency = performance.now() - timestamp;
    console.log(`🎮 Input: ${type} at (${x}, ${y}) - Latency: ${latency.toFixed(1)}ms`);
    
    // Send to native binary via existing API
    this.executeInput(type, x, y, button);
  }

  getInputTypeFromCode(code) {
    const types = ['unknown', 'mousedown', 'mouseup', 'mousemove', 'click', 'keydown', 'keyup'];
    return types[code] || 'unknown';
  }

  async executeInput(type, x, y, button) {
    // Use existing coordinate system fix
    const payload = { x, y };
    if (button) payload.button = button;
    
    let endpoint = '/click';
    if (window.currentCaptureMode === 'window' && window.currentWindowID) {
      endpoint = '/click-window';
      payload.cgWindowID = window.currentWindowID;
    }
    
    try {
      await fetch(`http://127.0.0.1:8080${endpoint}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      });
    } catch (error) {
      console.error('Failed to execute input:', error);
    }
  }

  displayStream(stream) {
    const video = document.getElementById('webrtc-video') || this.createVideoElement();
    video.srcObject = stream;
    video.play();
    
    // Add input handlers
    this.setupInputHandlers(video);
  }

  createVideoElement() {
    const video = document.createElement('video');
    video.id = 'webrtc-video';
    video.autoplay = true;
    video.muted = true;
    video.style.width = '100%';
    video.style.height = '100%';
    video.style.objectFit = 'contain';
    
    document.body.appendChild(video);
    return video;
  }

  setupInputHandlers(video) {
    // Mouse events
    video.addEventListener('click', (e) => {
      const rect = video.getBoundingClientRect();
      const x = (e.clientX - rect.left) * (video.videoWidth / rect.width);
      const y = (e.clientY - rect.top) * (video.videoHeight / rect.height);
      
      this.sendInput('click', x, y, e.button);
    });

    video.addEventListener('mousemove', (e) => {
      const rect = video.getBoundingClientRect();
      const x = (e.clientX - rect.left) * (video.videoWidth / rect.width);
      const y = (e.clientY - rect.top) * (video.videoHeight / rect.height);
      
      this.sendInput('mousemove', x, y);
    });

    // Keyboard events
    document.addEventListener('keydown', (e) => {
      e.preventDefault();
      this.sendInput('keydown', 0, 0, 0, e.key);
    });
  }

  async createOffer() {
    const offer = await this.peerConnection.createOffer({
      offerToReceiveAudio: false,
      offerToReceiveVideo: false
    });
    
    await this.peerConnection.setLocalDescription(offer);
    return offer;
  }

  async handleOffer(offer) {
    await this.peerConnection.setRemoteDescription(offer);
    const answer = await this.peerConnection.createAnswer();
    await this.peerConnection.setLocalDescription(answer);
    return answer;
  }

  async handleAnswer(answer) {
    await this.peerConnection.setRemoteDescription(answer);
  }

  async addIceCandidate(candidate) {
    await this.peerConnection.addIceCandidate(candidate);
  }

  // Cleanup
  stop() {
    if (this.stream) {
      this.stream.getTracks().forEach(track => track.stop());
    }
    if (this.peerConnection) {
      this.peerConnection.close();
    }
    if (this.dataChannel) {
      this.dataChannel.close();
    }
  }
}

// Usage example:
// Server (screen sharer):
// const server = new WebRTCScreenShare();
// const offer = await server.startServer();
// // Send offer to client via signaling

// Client (viewer):
// const client = new WebRTCScreenShare();
// await client.startClient();
// const answer = await client.handleOffer(receivedOffer);
// // Send answer back via signaling

module.exports = WebRTCScreenShare;