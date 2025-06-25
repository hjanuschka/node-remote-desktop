#!/bin/bash

echo "🧪 Testing WebRTC Hardware Acceleration Mode"
echo "==========================================="

# Test desktop capture with WebRTC mode
echo -e "\n1️⃣ Testing desktop capture with WebRTC mode:"
curl -X POST http://127.0.0.1:8080/capture \
  -H "Content-Type: application/json" \
  -d '{"type": 0, "index": 0, "webrtc": true}' | jq .

sleep 2

# Test desktop capture with standard MJPEG mode
echo -e "\n2️⃣ Testing desktop capture with standard MJPEG mode:"
curl -X POST http://127.0.0.1:8080/capture \
  -H "Content-Type: application/json" \
  -d '{"type": 0, "index": 0, "webrtc": false}' | jq .

sleep 2

# Get display info
echo -e "\n3️⃣ Getting display info:"
curl http://127.0.0.1:8080/display | jq .

echo -e "\n✅ WebRTC mode test completed!"
echo "Check the server logs for:"
echo "  - '🚀 Starting capture with WebRTC hardware acceleration enabled'"
echo "  - '📸 Starting capture with standard MJPEG mode'"
echo "  - '🎥 WebRTC H.264 encoded X frames' messages"