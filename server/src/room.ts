import type { WebSocket } from "ws";
import type { Page, Peer, ServerMessage, Stroke } from "./protocol.ts";
import type { RoomStore } from "./db.ts";

type Member = {
  peer: Peer;
  socket: WebSocket;
};

export class Room {
  readonly id: string;
  private members = new Map<string, Member>();
  private strokes: Stroke[] = [];
  // Fast lookup by stroke id for point/end appends
  private strokeIndex = new Map<string, Stroke>();
  private page: Page | null = null;
  private store?: RoomStore;

  /**
   * When a `store` is provided, completed strokes and page changes are
   * persisted, and cold-starting a room loads its history from disk.
   */
  constructor(id: string, store?: RoomStore) {
    this.id = id;
    this.store = store;
    if (store) {
      store.ensureRoom(id);
      this.page = store.getPage(id);
      this.strokes = store.loadStrokes(id);
    }
  }

  snapshotPage(): Page | null {
    return this.page;
  }

  setPage(userId: string, page: Page | null): void {
    this.page = page;
    this.store?.setPage(this.id, page);
    this.broadcast({ type: "page_changed", userId, page }, userId);
  }

  clearCanvas(userId: string): void {
    this.strokes = [];
    this.strokeIndex.clear();
    this.store?.clearStrokes(this.id);
    this.broadcast({ type: "canvas_cleared", userId }, userId);
  }

  get peerCount(): number {
    return this.members.size;
  }

  snapshotPeers(): Peer[] {
    return Array.from(this.members.values()).map((m) => ({ ...m.peer }));
  }

  snapshotStrokes(): Stroke[] {
    // Return a shallow copy; strokes are effectively immutable once complete,
    // but in-flight strokes keep accumulating points.
    return this.strokes.map((s) => ({ ...s, points: [...s.points] }));
  }

  addMember(peer: Peer, socket: WebSocket): void {
    this.members.set(peer.userId, { peer, socket });
    this.store?.touchRoom(this.id);
    this.broadcast({ type: "peer_joined", peer }, peer.userId);
  }

  removeMember(userId: string): void {
    const existed = this.members.delete(userId);
    if (existed) {
      this.broadcast({ type: "peer_left", userId });
    }
    // Drop any in-flight strokes from this user so late joiners don't see
    // an orphan "incomplete" stroke forever. Persist them if they have any
    // points — better to save a short stroke than lose the user's work.
    for (const [id, s] of this.strokeIndex) {
      if (s.userId === userId && !s.complete) {
        s.complete = true;
        if (s.points.length > 0) this.store?.insertStroke(this.id, s);
        this.strokeIndex.delete(id);
      }
    }
  }

  beginStroke(
    userId: string,
    header: Omit<Stroke, "points" | "complete"> & { point: import("./protocol.ts").Point },
  ): void {
    const { point, ...rest } = header;
    const stroke: Stroke = { ...rest, points: [point], complete: false };
    this.strokes.push(stroke);
    this.strokeIndex.set(stroke.id, stroke);
    this.broadcast(
      { type: "stroke_start", userId, stroke: { ...rest, point } },
      userId,
    );
  }

  appendPoint(
    userId: string,
    strokeId: string,
    point: import("./protocol.ts").Point,
  ): void {
    const stroke = this.strokeIndex.get(strokeId);
    if (!stroke || stroke.userId !== userId || stroke.complete) return;
    stroke.points.push(point);
    this.broadcast({ type: "stroke_point", userId, strokeId, point }, userId);
  }

  endStroke(userId: string, strokeId: string): void {
    const stroke = this.strokeIndex.get(strokeId);
    if (!stroke || stroke.userId !== userId) return;
    stroke.complete = true;
    this.store?.insertStroke(this.id, stroke);
    this.strokeIndex.delete(strokeId);
    this.broadcast({ type: "stroke_end", userId, strokeId }, userId);
  }

  updateCursor(userId: string, x: number, y: number): void {
    const m = this.members.get(userId);
    if (!m) return;
    m.peer.cursor = { x, y };
    this.broadcast({ type: "cursor", userId, x, y }, userId);
  }

  private broadcast(msg: ServerMessage, exceptUserId?: string): void {
    const payload = JSON.stringify(msg);
    for (const [id, m] of this.members) {
      if (id === exceptUserId) continue;
      if (m.socket.readyState === m.socket.OPEN) {
        m.socket.send(payload);
      }
    }
  }
}
