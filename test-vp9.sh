#!/bin/bash

echo "🧪 Testing VP9 Mode"
echo "=================="

# Test enabling VP9 mode
echo -e "\n1️⃣ Testing VP9 mode enable:"
curl -X POST http://127.0.0.1:8080/capture \
  -H "Content-Type: application/json" \
  -d '{"type": 0, "index": 0, "vp9": true}' | jq .

sleep 3

# Test getting VP9 frame
echo -e "\n2️⃣ Testing VP9 frame fetch:"
response=$(curl -s -w "%{http_code}" http://127.0.0.1:8080/vp9-frame -o /tmp/vp9_frame.bin)
echo "Response code: $response"
if [ -f /tmp/vp9_frame.bin ]; then
    size=$(wc -c < /tmp/vp9_frame.bin)
    echo "Frame size: $size bytes"
    if [ $size -gt 0 ]; then
        echo "✅ VP9 frame received successfully!"
    else
        echo "❌ VP9 frame is empty"
    fi
else
    echo "❌ No VP9 frame file created"
fi

# Test disabling VP9 mode
echo -e "\n3️⃣ Testing VP9 mode disable:"
curl -X POST http://127.0.0.1:8080/capture \
  -H "Content-Type: application/json" \
  -d '{"type": 0, "index": 0, "vp9": false}' | jq .

echo -e "\n✅ VP9 test completed!"
echo "Check server logs for VP9 encoder initialization messages"