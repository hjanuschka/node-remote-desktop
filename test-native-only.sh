#!/bin/bash

echo "🧪 Testing Native Binary Directly"
echo "================================="

PORT=8092
echo "Starting native binary on port $PORT..."

# Start the native binary in background
cd /Users/hjanuschka/node-sharer/native/osx
./screencap7 $PORT &
BINARY_PID=$!

sleep 3

echo -e "\n1️⃣ Testing display info:"
curl -s http://127.0.0.1:$PORT/display | jq .

echo -e "\n2️⃣ Testing standard capture:"
curl -X POST http://127.0.0.1:$PORT/capture \
  -H "Content-Type: application/json" \
  -d '{"type": 0, "index": 0, "vp9": false}' | jq .

sleep 2

echo -e "\n3️⃣ Testing frame retrieval:"
response=$(curl -s -w "%{http_code}" http://127.0.0.1:$PORT/frame -o /tmp/test_standard.jpg)
echo "Standard frame: HTTP $response, Size: $(wc -c < /tmp/test_standard.jpg) bytes"

echo -e "\n4️⃣ Testing High Quality capture:"
curl -X POST http://127.0.0.1:$PORT/capture \
  -H "Content-Type: application/json" \
  -d '{"type": 0, "index": 0, "vp9": true}' | jq .

sleep 2

echo -e "\n5️⃣ Testing HQ frame retrieval:"
response=$(curl -s -w "%{http_code}" http://127.0.0.1:$PORT/frame -o /tmp/test_hq.jpg)
echo "HQ frame: HTTP $response, Size: $(wc -c < /tmp/test_hq.jpg) bytes"

echo -e "\n6️⃣ Comparing frame sizes:"
ls -la /tmp/test_*.jpg

# Kill the binary
kill $BINARY_PID 2>/dev/null

echo -e "\n✅ Native binary test completed!"
echo "If this works, the issue is in Node.js integration"