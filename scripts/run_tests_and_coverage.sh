#!/usr/bin/env/bash
# Run unit tests and print coverage for CursorConnector (Companion + iOS instructions).
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=============================================="
echo " CursorConnector – Unit tests & coverage"
echo "=============================================="

# 1. Companion (Swift Package) tests + coverage
echo ""
echo "--- Companion (Swift Package) ---"
cd "$REPO_ROOT/Companion"
swift test --enable-code-coverage 2>&1 | tail -5
echo ""
echo "Companion code coverage:"
xcrun llvm-cov report .build/arm64-apple-macosx/debug/Companion \
  -instr-profile=.build/arm64-apple-macosx/debug/codecov/default.profdata \
  -ignore-filename-regex='.build|Tests' 2>/dev/null || true

# 2. iOS unit tests (no coverage in script to avoid simulator issues; run in Xcode for coverage)
echo ""
echo "--- iOS (Xcode) ---"
echo "To run iOS unit tests with coverage:"
echo "  1. Open ios/CursorConnector.xcodeproj in Xcode"
echo "  2. Product → Test (Cmd+U), or run:"
echo "     xcodebuild test -scheme CursorConnector -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' -only-testing:CursorConnectorTests"
echo "  3. For coverage: Edit Scheme → Test → Options → check Code Coverage, then run tests and see Report navigator → Coverage"
echo ""
