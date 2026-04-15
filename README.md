# Coloring Book

A real-time collaborative coloring experience for macOS. The trackpad is the paper: one finger draws, two fingers reposition the pen without inking. Strokes sync between clients over WebSocket.

## Architecture

- **`macos-app/`** — Swift macOS app. SwiftUI shell, Metal-rendered canvas, `NSEvent` multi-touch trackpad capture, `URLSessionWebSocketTask` for sync.
- **`server/`** — Node.js + TypeScript WebSocket server. In-memory rooms, JSON protocol, append-only stroke log.

## Gesture model

The trackpad is mapped 1:1 to the canvas. The first finger on the trackpad is the pen tip.

| Fingers | Mode | Effect |
|---|---|---|
| 0 | Idle | Pen cursor holds last position |
| 1 | Drawing | Pen presses paper, ink flows along the finger's path |
| 2+ | Hovering | Pen lifts off paper, cursor tracks primary finger, no ink |

## Running

**1. Start the server** (port 8787)

```sh
cd server
npm install
npm run dev
```

The server uses SQLite for persistence — rooms, strokes, and pages survive restarts. The DB file defaults to `server/coloring-book.db`. Override with env vars:

```sh
PORT=9000 DB_PATH=/var/lib/coloringbook/state.db npm start
```

**2. Run the macOS app**

Quickest for dev work (no camera):

```sh
cd macos-app
swift run ColoringBook
```

Use `ROOM` env var to join a specific room (default `lobby`):

```sh
ROOM=alpha swift run ColoringBook
```

Launch multiple instances with the same `ROOM` to collaborate.

**3. Build as a proper .app bundle (needed for camera capture)**

`swift run` launches a bare executable — it has no Info.plist, so the camera permission prompt silently fails. To use the **Capture with camera** feature, build a real app bundle:

```sh
cd macos-app
bash scripts/build-app.sh
open dist/ColoringBook.app
```

The first camera use prompts for permission; macOS remembers the grant after that.

## Wire protocol

JSON over WebSocket. Client connects to `ws://localhost:8787/?room=<id>&userId=<id>&name=<name>&color=<hex>`.

**Client → Server**

- `{ type: 'stroke_start', stroke: { id, tool, color, brushSize, point } }`
- `{ type: 'stroke_point', strokeId, point }`
- `{ type: 'stroke_end', strokeId }`
- `{ type: 'cursor', x, y }`

**Server → Client**

- `{ type: 'room_state', strokes: [...], peers: [...], you: { userId } }` (on join)
- `{ type: 'peer_joined' | 'peer_left', ... }`
- `{ type: 'stroke_start' | 'stroke_point' | 'stroke_end', userId, ... }`
- `{ type: 'cursor', userId, x, y }`

## Accounts and friends

- On first launch you see a login screen. Create an account (username + password, no email). Username is 3–20 chars (letters / numbers / underscore), password ≥ 8 chars. Case-insensitive for login; display preserves original casing.
- After signup you're logged in. Your session token is stored in the macOS Keychain, so you stay logged in across launches.
- Click the **+** in the Friends panel to send a friend request by username. Mutual requests auto-accept. Each friend gets a green dot when they're online (any active WS connection).
- Click a friend to open a **DM room** with them — a room scoped to the two of you. Server enforces that only the two participants can join `dm:<a>:<b>` rooms (and they must be accepted friends). All the canvas state (strokes + current page) persists in SQLite.
- There's no password recovery without email — losing a password means making a new account. Trade-off of the minimal-auth model.

## Pages and importing drawings

Open the **Page** section in the side panel:

- **Built-in pages**: Blank, Mandala, Tulip, Cottage (all procedurally drawn in Core Graphics, no image assets).
- **Import drawing…**: pick a photo of a drawing from disk. Vision's document segmentation finds the page, `CIPerspectiveCorrection` flattens it, and a contrast / alpha-extract filter turns it into black lines on transparent. Works best on pen/marker sketches under even light.
- **Capture with camera** (requires .app bundle): live webcam preview with real-time page detection; hit Capture when the detected quad looks right. Same Vision pipeline as file import.
- **Clear canvas**: wipes all strokes in the room (broadcast to peers).

Pages are synced to the whole room — if one user changes the page, every peer's canvas updates.

## Deployment

The server is plain Node + SQLite — lives happily on a small Ubuntu host.

**systemd unit** (`/etc/systemd/system/coloring-book.service`):

```ini
[Unit]
Description=Coloring Book collab server
After=network.target

[Service]
Type=simple
User=coloringbook
WorkingDirectory=/opt/coloring-book/server
Environment=PORT=8787
Environment=DB_PATH=/var/lib/coloringbook/state.db
ExecStart=/usr/bin/npm start
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
```

**TLS + WSS via Caddy** (native `ws://` to a public host is blocked by macOS App Transport Security; you need `wss://`):

```caddyfile
coloringbook.example.com {
    reverse_proxy localhost:8787
}
```

Caddy handles Let's Encrypt automatically. In the macOS app, set the server URL via the `SERVER` env var or hardcode `wss://coloringbook.example.com` in `SessionModel.init`.

**Backup**: SQLite is a single file. Nightly cron:

```sh
0 4 * * *  sqlite3 /var/lib/coloringbook/state.db ".backup /backups/state-$(date +\%F).db"
```

## Roadmap

- 200-shade palette with tool-specific variants.
- Test swatch area.
- Undo / stroke history.
- Persistence (rooms survive server restarts).
- App sandboxing + proper notarization for distribution.
- Two-finger pan when zoomed in.
