import { createServer, type IncomingMessage } from "node:http";
import { WebSocketServer, type WebSocket } from "ws";
import { Room } from "./room.ts";
import { openStore, type Store } from "./db.ts";
import { handleHTTP } from "./http.ts";
import type { ClientMessage, Peer, ServerMessage } from "./protocol.ts";

type JoinParams = {
  roomId: string;
  userId: string;
  name: string;
  color: string;
};

/// Validated join params: reads `token`, `room`, `color` from the URL, resolves
/// the token to a user, and enforces DM-room membership (rooms named
/// `dm:<a>:<b>` may only be joined by user <a> or user <b>).
function parseJoin(
  req: IncomingMessage,
  store: Store
): { ok: true; params: JoinParams } | { ok: false; reason: string; code: number } {
  const url = new URL(req.url ?? "/", "http://localhost");
  const token = url.searchParams.get("token");
  if (!token) return { ok: false, reason: "missing token", code: 4401 };
  const user = store.lookupSession(token);
  if (!user) return { ok: false, reason: "invalid session", code: 4401 };

  const roomId = (url.searchParams.get("room") ?? "lobby").slice(0, 128);
  const color = (url.searchParams.get("color") ?? "#888888").slice(0, 16);

  // DM-room access control: dm:<min>:<max> only joinable by those two users.
  if (roomId.startsWith("dm:")) {
    const parts = roomId.split(":");
    if (parts.length !== 3 || !parts[1] || !parts[2]) {
      return { ok: false, reason: "malformed dm room id", code: 4400 };
    }
    const [, a, b] = parts;
    if (user.id !== a && user.id !== b) {
      return { ok: false, reason: "not a member of this room", code: 4403 };
    }
    // Also: the two users must actually be friends.
    if (!store.areFriends(a!, b!)) {
      return { ok: false, reason: "not friends with the other user", code: 4403 };
    }
  }

  // Solo-room access control: solo:<userId> is the owner's private sketchbook.
  if (roomId.startsWith("solo:")) {
    const ownerId = roomId.slice("solo:".length);
    if (!ownerId || user.id !== ownerId) {
      return { ok: false, reason: "not your sketchbook", code: 4403 };
    }
  }

  return {
    ok: true,
    params: {
      roomId,
      userId: user.id,
      name: user.displayName,
      color,
    },
  };
}

function send(ws: WebSocket, msg: ServerMessage): void {
  if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(msg));
}

export function startServer(port: number, dbPath: string): void {
  const store: Store = openStore(dbPath);
  const rooms = new Map<string, Room>();
  /// Tracks which userIds are currently connected (any room) — powers the
  /// "online" dot in friend lists.
  const online = new Map<string, number>();

  const getRoom = (id: string): Room => {
    const existing = rooms.get(id);
    if (existing) return existing;
    const room = new Room(id, store);
    rooms.set(id, room);
    return room;
  };

  // Graceful shutdown so SQLite flushes its WAL.
  const shutdown = () => {
    try { store.close(); } catch { /* ignore */ }
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);

  const httpSrv = createServer(async (req, res) => {
    const handled = await handleHTTP(req, res, {
      store,
      isOnline: (id) => (online.get(id) ?? 0) > 0,
    });
    if (handled) return;
    res.writeHead(200, { "content-type": "text/plain" });
    res.end("coloring-book server — connect via WebSocket\n");
  });

  const wss = new WebSocketServer({ server: httpSrv });

  wss.on("connection", (ws, req) => {
    const parsed = parseJoin(req, store);
    if (!parsed.ok) {
      ws.close(parsed.code, parsed.reason);
      return;
    }
    const join = parsed.params;

    const room = getRoom(join.roomId);
    const peer: Peer = {
      userId: join.userId,
      name: join.name,
      color: join.color,
    };

    online.set(peer.userId, (online.get(peer.userId) ?? 0) + 1);

    send(ws, {
      type: "room_state",
      strokes: room.snapshotStrokes(),
      peers: room.snapshotPeers(),
      you: { userId: peer.userId },
      page: room.snapshotPage(),
    });
    room.addMember(peer, ws);

    console.log(
      `[${new Date().toISOString()}] join room=${room.id} user=${peer.userId} (${room.peerCount} total)`,
    );

    ws.on("message", (raw) => {
      let msg: ClientMessage;
      try {
        msg = JSON.parse(raw.toString()) as ClientMessage;
      } catch {
        return;
      }
      switch (msg.type) {
        case "stroke_start":
          if (msg.stroke.userId !== peer.userId) return;
          room.beginStroke(peer.userId, msg.stroke);
          break;
        case "stroke_point":
          room.appendPoint(peer.userId, msg.strokeId, msg.point);
          break;
        case "stroke_end":
          room.endStroke(peer.userId, msg.strokeId);
          break;
        case "cursor":
          room.updateCursor(peer.userId, msg.x, msg.y);
          break;
        case "set_page":
          room.setPage(peer.userId, msg.page);
          break;
        case "clear_canvas":
          room.clearCanvas(peer.userId);
          break;
      }
    });

    const handleClose = () => {
      room.removeMember(peer.userId);
      const remainingRefs = (online.get(peer.userId) ?? 1) - 1;
      if (remainingRefs <= 0) online.delete(peer.userId);
      else online.set(peer.userId, remainingRefs);
      console.log(
        `[${new Date().toISOString()}] leave room=${room.id} user=${peer.userId} (${room.peerCount} remaining)`,
      );
    };
    ws.on("close", handleClose);
    ws.on("error", (err) => {
      console.warn("ws error:", err);
      handleClose();
    });
  });

  httpSrv.listen(port, () => {
    console.log(
      `coloring-book server listening on ws://localhost:${port} (db=${dbPath})`
    );
  });
}
