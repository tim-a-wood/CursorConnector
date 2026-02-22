# CursorConnector

A simple iOS app for personal use that lets you remotely connect to a Cursor project on your MacBook: send prompts, view agent output, browse the project, and build/test the Xcode project.

## Status

| Item | Status |
|------|--------|
| **Phase** | Phase 3 — done |
| **Implemented** | Chat-style iOS UI; Settings (host, port, projects, connect); conversation + agent output; file browser and **edit** (Companion **POST /files/content**). |
| **Planned** | Phase 4: build & test; Phase 5: polish/remote. |

See [.cursor/prompts/project-status.md](.cursor/prompts/project-status.md) for detailed progress and next steps.

## Project structure

```
CursorConnector/
├── .cursor/prompts/        # project-context, overview, plan, status
├── Companion/              # Mac companion (Swift package, HTTP server)
│   ├── Package.swift
│   └── Sources/main.swift
├── ios/                    # iOS app
│   ├── CursorConnector.xcodeproj
│   ├── project.yml         # optional: XcodeGen spec
│   └── CursorConnector/    # app source (SwiftUI)
├── rules/                 # Cursor rules
└── README.md
```

## Getting started

### 1. Run the Mac companion

On your Mac (where Cursor and your projects live):

```bash
cd Companion
swift run
```

Companion listens on **http://localhost:9283** and:

- **GET /health** — health check  
- **GET /projects** — list recent Cursor projects (from Cursor’s `state.vscdb` or `~/.cursor-connector-projects.json`)  
- **POST /projects/open** — body `{"path": "/absolute/path"}` opens that folder in Cursor (uses `cursor` CLI; install via Cursor: *Shell Command: Install 'cursor' command*)  
- **POST /restart** — exit the Companion (iOS **Restart server** button). To have it come back automatically, run on Mac: `while true; do (cd Companion && swift run); sleep 2; done`.
- **POST /prompt** — body `{"path": "/project/path", "prompt": "..."}` runs the Cursor Agent CLI in that directory and returns `{"output": "...", "exitCode": N}` (requires [Cursor Agent CLI](https://cursor.com/docs/cli/overview): `curl https://cursor.com/install -fsSL | bash`). The agent needs a Cursor API key: create **`~/.cursor-connector-api-key`** with your key on the first line (get one from [Cursor Dashboard → Integrations](https://cursor.com/dashboard?tab=integrations)).
- **GET /files/tree** — query `path=/absolute/dir` lists directory contents. **GET /files/content** — query `path=/absolute/file` returns file body. **POST /files/content** — body `{"path": "/absolute/file", "content": "..."}` writes a text file.

If Cursor’s DB is locked or empty, add a fallback list at `~/.cursor-connector-projects.json`:

```json
[
  {"path": "/Users/you/projects/MyApp", "label": "MyApp"},
  {"path": "/Users/you/projects/Other", "label": "Other"}
]
```

Or a simple path array: `["/path/to/a", "/path/to/b"]`.

### 2. Open the iOS app and run on your iPhone

1. Open `ios/CursorConnector.xcodeproj` in Xcode.  
2. In the toolbar, set the run destination to **Your iPhone** (not a simulator). Connect your device via USB if needed.  
3. Select the **CursorConnector** scheme and press **Run** (⌘R).  
4. On first run, if you see “Untrusted Developer”: on the iPhone go to **Settings → General → VPN & Device Management** and trust your Apple ID.  
5. The app uses a **chat-style UI**: tap **Settings** (gear), enter your Mac’s **Host** (IP or hostname) and port `9283`, tap **Refresh projects**, then tap a project to connect. Return to the chat, type a message and send to run the agent. Use **Files** to browse and edit project files.

### 3. Same network

iOS device and Mac must be on the same LAN (or reachable via VPN/Tailscale). Use your Mac’s local IP in the app.

### If you see “Could not connect to the server”

1. **Companion running?** On the Mac, run `cd Companion && swift run` and leave it running. You should see “CursorConnector Companion running on http://localhost:9283”.
2. **Correct host?** In the app use your Mac’s IP (e.g. `192.168.1.x`) or hostname (e.g. `MacBook.local`). Get IP: System Settings → Network, or in Terminal: `ipconfig getifaddr en0` (Wi‑Fi).
3. **Port 9283** — no change needed unless you changed the companion port.
4. **Same Wi‑Fi** — iPhone and Mac must be on the same network (not guest or a different band that’s isolated).
5. **Mac firewall** — If you have a firewall on, allow incoming connections for the Companion (or allow port 9283). System Settings → Network → Firewall (or Security & Privacy → Firewall) → Options, and add the Companion app or allow incoming on port 9283.
6. **Test from Mac** — In Terminal on the Mac run: `curl -s http://localhost:9283/health` — you should see `OK`. Then from another machine on the same network: `curl -s http://YOUR_MAC_IP:9283/health`.

### Connection when the display is off (battery saving)

The Companion prevents **system** idle sleep so the Mac stays reachable, but allows the **display** to sleep to save battery. If the connection still drops when your Mac’s screen times out, try:

- **System Settings → Lock Screen** (or **Battery**): enable **“Prevent automatic sleeping when the display is off”** (or the equivalent on your macOS version). The display can still turn off; the Mac stays awake so the iOS app can reconnect.
- The iOS app will show “Mac unreachable. Reconnecting…” and retry every few seconds; when the Mac is reachable again (e.g. after you wake it), it reconnects automatically.

## Roadmap

| Phase | Focus |
|-------|--------|
| 1 ✅ | Foundation — Mac companion, project list, connect from iOS |
| 2 ✅ | Prompts and agent output |
| 3 ✅ | Project browser (file tree, view/edit files); chatbot UI; config in Settings |
| 4 | Build and test (xcodebuild, logs) |
| 5 | Polish and optional remote access |

## Tech stack

- **Mac companion**: Swift 5.9, Swifter (HTTP server), reads Cursor’s `state.vscdb`; opens projects via `cursor` CLI; runs prompts via Cursor Agent CLI (`agent chat "..."`) with 5‑min timeout.  
- **iOS**: SwiftUI, iOS 17+, minimal dependencies.  
- **Transport**: HTTP (local network); Phase 5 may add remote (e.g. Tailscale).
