#!/bin/bash

echo "🎯 Coordinate Testing Script for Node Sharer"
echo "==========================================="
echo ""

# Check if server is running
if ! curl -s http://localhost:3030 > /dev/null; then
    echo "❌ Server not running on port 3030"
    echo "Please start the server first with: node server.js"
    exit 1
fi

echo "✅ Server is running"
echo ""

# Get current coordinate info
echo "📊 Current Configuration:"
curl -s http://localhost:3030/coord-info | jq '.'
echo ""

echo "🧪 Test Options:"
echo "1) Test desktop capture coordinates"
echo "2) Test window capture coordinates"
echo "3) Enable debug mode and restart"
echo "4) Start coordinate test app (fullscreen)"
echo "5) Start coordinate test app (windowed)"
echo ""

read -p "Select option (1-5): " option

case $option in
    1)
        echo "🖥️ Opening desktop capture test..."
        open "http://localhost:3030/?test=desktop"
        echo ""
        echo "Instructions:"
        echo "1. Click on the desktop capture option"
        echo "2. Try clicking on various screen elements"
        echo "3. Watch the console for coordinate debug output"
        ;;
    2)
        echo "🪟 Opening window capture test..."
        open "http://localhost:3030/?test=window"
        echo ""
        echo "Instructions:"
        echo "1. Select a window to capture"
        echo "2. Try clicking within the window"
        echo "3. Watch the console for coordinate debug output"
        ;;
    3)
        echo "🔧 Enabling debug mode..."
        echo ""
        echo "To enable debug mode, restart the server with:"
        echo "DEBUG_COORDS=true node server.js"
        echo ""
        echo "This will show visual indicators where clicks are registered"
        ;;
    4)
        echo "🎯 Starting fullscreen coordinate test app..."
        curl -s http://localhost:3030/coordtest
        echo ""
        echo "The test app will show a grid with coordinates"
        echo "Click on specific coordinates to test accuracy"
        ;;
    5)
        echo "🎯 Starting windowed coordinate test app..."
        curl -s "http://localhost:3030/coordtest?windowed=true"
        echo ""
        echo "A 500x500 window will appear with coordinate grid"
        echo "Test clicking within the window"
        ;;
    *)
        echo "Invalid option"
        ;;
esac

echo ""
echo "💡 Tips for testing:"
echo "- Enable DEBUG_COORDS=true for visual feedback"
echo "- Check server logs for detailed coordinate calculations"
echo "- Compare clicked position with actual mouse events"
echo "- Test both Retina and non-Retina displays if possible"