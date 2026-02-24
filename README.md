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

### 3. Same network (or remote)

- **Same LAN**: Use your Mac’s local IP in the app (e.g. `192.168.1.x`). iOS device and Mac must be on the same Wi‑Fi.
- **Other networks**: You can use the app from anywhere in two ways:
  1. **Tunnel (ngrok, Cloudflare Tunnel, etc.)**  
     On your Mac, expose the Companion with a tunnel, then put the tunnel URL in the app’s **Host** field (port is ignored). Example with [ngrok](https://ngrok.com): run `ngrok http 9283`, then in the app set Host to `https://abc123.ngrok-free.app` (or the URL ngrok shows). Leave port as 9283 or any value.
  2. **Tailscale (or similar VPN)**  
     Install [Tailscale](https://tailscale.com) on your Mac and iPhone. In the app, use your Mac’s **Tailscale IP** (e.g. `100.x.x.x`) and port `9283`. No tunnel needed.

### If you see “Could not connect to the server”

1. **Companion running?** On the Mac, run `cd Companion && swift run` and leave it running. You should see “CursorConnector Companion running on http://localhost:9283”.
2. **Correct host?** Same network: use your Mac’s IP (e.g. `192.168.1.x`) or hostname (e.g. `MacBook.local`). Get IP: System Settings → Network, or in Terminal: `ipconfig getifaddr en0` (Wi‑Fi). Other networks: use a tunnel URL (e.g. `https://xxx.ngrok.io`) or your Mac’s Tailscale IP.
3. **Port 9283** — no change needed unless you changed the companion port.
4. **Same Wi‑Fi** — iPhone and Mac must be on the same network (not guest or a different band that’s isolated).
5. **Mac firewall** — If you have a firewall on, allow incoming connections for the Companion (or allow port 9283). System Settings → Network → Firewall (or Security & Privacy → Firewall) → Options, and add the Companion app or allow incoming on port 9283.
6. **Test from Mac** — In Terminal on the Mac run: `curl -s http://localhost:9283/health` — you should see `OK`. Then from another machine on the same network: `curl -s http://YOUR_MAC_IP:9283/health`.

### Connection when the display is off (battery saving)

The Companion prevents **system** idle sleep so the Mac stays reachable, but allows the **display** to sleep to save battery. If the connection still drops when your Mac’s screen times out, try:

- **System Settings → Lock Screen** (or **Battery**): enable **“Prevent automatic sleeping when the display is off”** (or the equivalent on your macOS version). The display can still turn off; the Mac stays awake so the iOS app can reconnect.
- The iOS app will show “Mac unreachable. Reconnecting…” and retry every few seconds; when the Mac is reachable again (e.g. after you wake it), it reconnects automatically.

### MacBook lid closed (Companion still reachable)

Closing the lid normally puts the Mac to sleep, so the Companion stops and the iOS app can’t connect. The Companion cannot override lid-close sleep. Options:

1. **Clamshell mode** — Plug in an **external display**, **keyboard**, and **power**. Close the lid. The Mac stays awake and the Companion keeps running. (Same network or Tailscale so the iPhone can reach the Mac’s IP.)
2. **Prevent sleep when on power (may work on some Macs)** — In Terminal:  
   `sudo pmset -c sleep 0` (never sleep when plugged in).  
   On some MacBooks the lid still forces sleep; if so, use clamshell mode.
3. **Run the Companion on another machine** — Use a Mac mini, desktop Mac, or a cloud VM that’s always on. Run `cd Companion && swift run` there and point the iOS app at that host (e.g. Tailscale IP or tunnel).

### Build button (install to iPhone)

The **Build** button in the app triggers a build on the Mac and installs to a connected device. Xcode only sees devices that are **connected by USB** or on the **same Wi‑Fi** (with wireless debugging). If you use Tailscale (or another network) to reach the Mac, the app can chat and browse files, but Build will fail with "No iOS device visible to Xcode" — Tailscale does not make the iPhone visible to Xcode. To use Build: connect the iPhone to the Mac with a cable, or be on the same Wi‑Fi and use wireless debugging. To get new builds when away from the Mac, use TestFlight (see below).

#### TestFlight setup (one-time)

1. **Apple Developer account** — Sign in with an Apple ID in Xcode (free account works; paid gives longer TestFlight validity).
2. **Create the app in App Store Connect** (if needed) — [App Store Connect](https://appstoreconnect.apple.com) → Apps → + → New App (e.g. name "CursorConnector", bundle ID same as in Xcode).
3. **Archive and upload from the Mac** — In Xcode: set the run destination to **Any iOS Device (arm64)** (not a simulator), then Product → Archive. When the Organizer appears, select the archive → Distribute App → App Store Connect → Upload. After processing, the build appears under TestFlight for that app.
4. **Enable TestFlight testing** — In App Store Connect → your app → TestFlight. Add yourself as an internal tester (same Apple ID team), or create an external group and get a **public link** (optional).
5. **On the iPhone** — Install the [TestFlight app](https://apps.apple.com/app/testflight/id899247664) from the App Store. Accept the invite or open the TestFlight link; install CursorConnector from TestFlight. For later updates, open TestFlight and tap Update on CursorConnector (or use the in‑app shortcut below).
6. **In CursorConnector** — Settings → **Updates** → tap **"Open TestFlight to update"**. Optionally paste your TestFlight invite link once so the button opens it directly. After that you don’t need to remember: tap the button when you want to install or update the app.

#### Build and upload to TestFlight from the app (one tap when on Tailscale)

When you're away from your Mac (e.g. connected via Tailscale), use the **TestFlight** button in the toolbar: it tells the Mac to archive the app, export an IPA, and upload it to App Store Connect. No device needs to be connected. After a few minutes, open TestFlight on the iPhone and tap Update.

**Before you use the TestFlight button — do this once:**

- **On the iPhone:** Install the [TestFlight app](https://apps.apple.com/app/testflight/id899247664) from the App Store. You need it to install or update CursorConnector after an upload (the button only uploads from the Mac; it doesn’t install on the phone).
- **On the Mac:** Open the CursorConnector iOS project in Xcode (`ios/CursorConnector.xcodeproj`). In the project settings, select the **CursorConnector** target → **Signing & Capabilities**. Turn on **Automatically manage signing**, choose your **Team**, and ensure the bundle ID is set (e.g. `com.cursorconnector.app`). If you’ve never archived this app before, set the run destination to **Any iOS Device (arm64)** (not a simulator), then do **Product → Archive** once in Xcode and cancel the Organizer — that can create the distribution provisioning profile. Then the TestFlight button’s export step can succeed.
- **Optional but recommended:** In [App Store Connect](https://appstoreconnect.apple.com), create an app with the same bundle ID as in Xcode (e.g. CursorConnector). You’ll need this for the first TestFlight build anyway; having it before the first upload can avoid confusion.

**One-time setup on the Mac:** Create `~/.cursor-connector-testflight` with three lines (or two if you omit Team ID):

1. Your **Apple ID** (email)
2. An **app-specific password** (appleid.apple.com → Sign-In and Security → App-Specific Passwords → generate one)
3. **Team ID** (optional; 10 characters from developer.apple.com/account — helps export if you have multiple teams)

Example:

```
you@example.com
abcd-efgh-ijkl-mnop
XXXXXXXXXX
```

Then restart the Companion. The **TestFlight** button in the iOS app (toolbar, next to Build) will archive, export, and upload; the request can take several minutes (build + upload).

**Export failed?** Check: (1) Team ID on line 3 of `~/.cursor-connector-testflight` is correct (10 characters from [developer.apple.com/account](https://developer.apple.com/account)); (2) In Xcode, Signing & Capabilities has a Team and “Automatically manage signing” is on; (3) Try **Product → Archive** once in Xcode and see if it succeeds — if it fails there, fix signing first.

**"No profiles for 'com.cursorconnector.app' were found"** — Do these in order (one-time): (1) **App Store Connect**: [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → Apps → + → New App → set bundle ID to **com.cursorconnector.app** (same as in Xcode). (2) **Xcode**: open `ios/CursorConnector.xcodeproj` → CursorConnector target → **Signing & Capabilities** → choose your **Team**, turn on **Automatically manage signing**. (3) **Xcode**: **Product → Archive** and wait until the Organizer appears (Xcode will create the distribution profile). You can then close the Organizer. After that, the TestFlight button should work.

## Roadmap

| Phase | Focus |
|-------|--------|
| 1 ✅ | Foundation — Mac companion, project list, connect from iOS |
| 2 ✅ | Prompts and agent output |
| 3 ✅ | Project browser (file tree, view/edit files); chatbot UI; config in Settings |
| 4 | Build and test (xcodebuild, logs) |
| 5 ✅ | Polish and optional remote access (tunnel URL or Tailscale in Host) |

## Tech stack

- **Mac companion**: Swift 5.9, Swifter (HTTP server), reads Cursor’s `state.vscdb`; opens projects via `cursor` CLI; runs prompts via Cursor Agent CLI (`agent chat "..."`) with 5‑min timeout.  
- **iOS**: SwiftUI, iOS 17+, minimal dependencies.  
- **Transport**: HTTP (local network or remote via tunnel URL / Tailscale).
