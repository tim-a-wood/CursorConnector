#!/usr/bin/env bash
# Rebuild and restart the CursorConnector Companion app.
# Usage: ./run.sh   (from Companion dir) or ./Companion/run.sh (from repo root)

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building Companion..."
swift build

# Kill any existing Companion or process on port 9283
EXISTING_PID=$(lsof -ti:9283 2>/dev/null || true)
if [ -n "$EXISTING_PID" ]; then
  echo "Stopping existing process on port 9283 (PID $EXISTING_PID)..."
  kill "$EXISTING_PID" 2>/dev/null || true
  sleep 1
  # Force kill if still running
  lsof -ti:9283 2>/dev/null | xargs kill -9 2>/dev/null || true
fi

echo "Starting Companion..."
exec .build/debug/Companion
