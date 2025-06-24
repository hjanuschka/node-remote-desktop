#!/bin/bash
set -e

echo "🔨 Building macOS Screen Capture Tool..."

# Compile the Objective-C screen capture tool
clang -framework Foundation \
      -framework AVFoundation \
      -framework CoreMedia \
      -framework CoreVideo \
      -framework ImageIO \
      -framework UniformTypeIdentifiers \
      -framework CoreImage \
      -framework CoreGraphics \
      -framework AppKit \
      -o screencap \
      screencap.m

echo "✅ Built screencap binary!"

echo "🔨 Building simple screen capture tool..."

# Build the simpler version
clang -framework Foundation \
      -framework CoreGraphics \
      -framework ImageIO \
      -framework UniformTypeIdentifiers \
      -o screencap2 \
      screencap2.m

echo "✅ Built screencap2 binary!"
echo "🚀 Test it with: ./screencap2 30 > test.mjpeg"

echo "🔨 Building ScreenCaptureKit version..."

# Build the ScreenCaptureKit version
clang -framework Foundation \
      -framework ScreenCaptureKit \
      -framework CoreMedia \
      -framework CoreVideo \
      -framework ImageIO \
      -framework UniformTypeIdentifiers \
      -framework CoreImage \
      -framework CoreGraphics \
      -o screencap3 \
      screencap3.m

echo "✅ Built screencap3 binary!"
echo "🚀 Test it with: ./screencap3 > test.mjpeg"