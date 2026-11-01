#!/bin/bash
# Builds ./beatlight. Needs Apple's Command Line Tools: xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"
clang -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter -mmacosx-version-min=13.0 \
  -o beatlight beatlight.m \
  -framework Foundation -framework Accelerate -framework AVFoundation -framework CoreGraphics \
  -framework CoreMedia -framework IOKit -framework ScreenCaptureKit
echo "Built ./beatlight — run ./beatlight -v"
