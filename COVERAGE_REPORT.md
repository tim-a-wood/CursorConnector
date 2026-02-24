# CursorConnector – Unit test coverage report

Generated after adding unit tests for the Companion package and the iOS app.

## Test summary

| Target | Tests | Status |
|--------|--------|--------|
| **Companion** (Swift Package) | 21 tests | ✅ All pass |
| **CursorConnector** (iOS) | 19 tests | ✅ All pass |

---

## Companion package coverage

Companion tests exercise pure helpers and file/git helpers; the rest of `main.swift` is server routes and process execution, so overall line coverage is low. The covered code paths are the ones most suitable for unit testing.

**Command used:**  
`swift test --enable-code-coverage` then  
`xcrun llvm-cov report .build/arm64-apple-macosx/debug/Companion -instr-profile=.build/arm64-apple-macosx/debug/codecov/default.profdata -ignore-filename-regex='.build|Tests'`

**Example output:**

```
Filename                                                                                   Regions    Missed Regions     Cover   Functions  Missed Functions  Executed       Lines      Missed Lines     Cover
------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
.../Companion/Sources/main.swift                                                             733               686     6.41%         138               126     8.70%        2004              1907     4.84%
------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------
TOTAL                                                                                        733               686     6.41%         138               126     8.70%        2004              1907     4.84%
```

**What’s tested (and covered):**

- `folderPath(fromUri:)` – file URI and percent encoding
- `validatePath` – absolute/relative, `..`, nonexistent paths
- `parseGitHubOwnerRepo` – HTTPS, SSH, `.git` suffix, invalid URLs
- `openProject` – path validation (empty, relative)
- `listDirectory` – valid dir, nonexistent
- `readFileContent` / `writeFileContent` – round-trip, path validation
- `isGitRepo` – non-repo
- `resolveIOSProjectPath` – nil/empty, invalid path

---

## iOS app coverage

iOS tests run in the simulator and cover models and API URL building.

**What’s tested:**

- **Conversation**
  - `titleFromMessages`: empty, assistant-only, first user message, first line only, 60-char truncation, whitespace-only
- **ChatMessage**
  - Encode/decode, default `thinking`
- **ProjectEntry**
  - `id == path`
- **CompanionAPI**
  - `baseURL(host:port:)`: host+port, default port, full URL, path/query stripped, empty host
- **ConversationStore**
  - Load summaries (nonexistent project), create + load, update, delete

**How to run:**

- In Xcode: **Product → Test** (⌘U).
- Command line (pick a destination that exists on your machine):
  ```bash
  xcodebuild test -scheme CursorConnector \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' \
    -only-testing:CursorConnectorTests
  ```

**How to get iOS code coverage:**

1. In Xcode: **Product → Scheme → Edit Scheme…**
2. Select **Test** → **Options**
3. Enable **Code Coverage**
4. Run tests (**Product → Test**)
5. Open **Report navigator** (⌘9) → select the last test run → **Coverage** tab

---

## Running tests and Companion coverage from the repo

From the repo root:

```bash
./scripts/run_tests_and_coverage.sh
```

This runs Companion tests with coverage and prints the coverage table; it also prints instructions for running iOS tests and viewing iOS coverage in Xcode.
