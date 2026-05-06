import type { WebSocket } from "ws";
import type {
  Page,
  Peer,
  Point,
  ServerMessage,
  StrokeHeader,
  Stroke,
  WireStroke,
} from "./protocol.ts";
import type { Store } from "./db.ts";

type Member = {
  peer: Peer;
  socket: WebSocket;
};

type ActiveStroke = Stroke & { pageId: string };

export class Room {
  readonly id: string;
  private members = new Map<string, Member>();

  /// All completed strokes for ALL pages in this room. Filtering happens at
  /// snapshot/persistence time. Lives in memory while the server is running;
  /// reloaded from SQLite on cold start.
  private strokes: ActiveStroke[] = [];
  private strokeIndex = new Map<string, ActiveStroke>();

  /// Pages keyed by pageId, in insertion order so we can re-emit a stable
  /// `pages` array.
  private pages: Page[] = [];
  private activePageId: string | null = null;

  private store?: Store;

  constructor(id: string, store?: Store) {
    this.id = id;
    this.store = store;
    if (!store) return;

    store.ensureRoom(id);
    this.pages = store.listPages(id);
    this.activePageId = store.getActivePageId(id);
    // If the stored active page is dangling (deleted somehow), fall back to
    // the first page in the list (or null).
    if (
      this.activePageId !== null &&
      !this.pages.find((p) => p.pageId === this.activePageId)
    ) {
      this.activePageId = this.pages[0]?.pageId ?? null;
    }
    // Pull every stroke that belongs to this room and demux by page_id.
    const allStrokes = store.loadStrokes(id);
    this.strokes = allStrokes.map((s) => ({ ...s }));
    // Strokes whose page_id refers to a missing page are treated as orphans
    // and silently dropped from the in-memory view (won't be re-served).
    this.strokes = this.strokes.filter((s) =>
      this.pages.some((p) => p.pageId === s.pageId)
    );
  }

  // ---- Snapshot for room_state -------------------------------------------

  snapshotPeers(): Peer[] {
    return Array.from(this.members.values()).map((m) => ({ ...m.peer }));
  }

  snapshotPages(): Page[] {
    return this.pages.map((p) => ({ ...p }));
  }

  snapshotActivePageId(): string | null {
    return this.activePageId;
  }

  snapshotStrokes(): WireStroke[] {
    return this.strokes.map((s) => ({
      id: s.id,
      userId: s.userId,
      tool: s.tool,
      color: s.color,
      brushSize: s.brushSize,
      pageId: s.pageId,
      points: [...s.points],
      complete: s.complete,
    }));
  }

  get peerCount(): number {
    return this.members.size;
  }

  // ---- Membership --------------------------------------------------------

  addMember(peer: Peer, socket: WebSocket): void {
    this.members.set(peer.userId, { peer, socket });
    this.store?.touchRoom(this.id);
    this.broadcast({ type: "peer_joined", peer }, peer.userId);
  }

  removeMember(userId: string): void {
    const existed = this.members.delete(userId);
    if (existed) this.broadcast({ type: "peer_left", userId });
    // Persist any in-flight strokes from this user (with ≥1 point) so a
    // disconnect mid-stroke doesn't lose work.
    for (const [id, s] of this.strokeIndex) {
      if (s.userId === userId && !s.complete) {
        s.complete = true;
        if (s.points.length > 0) {
          this.store?.insertStroke(this.id, s.pageId, s);
        }
        this.strokeIndex.delete(id);
      }
    }
  }

  // ---- Pages -------------------------------------------------------------

  addPage(userId: string, page: Page): void {
    // Idempotent: if pageId already exists, skip.
    if (this.pages.some((p) => p.pageId === page.pageId)) return;
    this.pages.push(page);
    const position = this.pages.length - 1;
    this.store?.insertPage(this.id, page, position);
    this.activePageId = page.pageId;
    this.store?.setActivePageId(this.id, page.pageId);
    this.broadcast({ type: "page_added", userId, page });
    this.broadcast({ type: "page_selected", userId, pageId: page.pageId });
  }

  selectPage(userId: string, pageId: string): void {
    if (!this.pages.some((p) => p.pageId === pageId)) return;
    if (this.activePageId === pageId) return;
    this.activePageId = pageId;
    this.store?.setActivePageId(this.id, pageId);
    this.broadcast({ type: "page_selected", userId, pageId });
  }

  deletePage(userId: string, pageId: string): void {
    const idx = this.pages.findIndex((p) => p.pageId === pageId);
    if (idx < 0) return;
    this.pages.splice(idx, 1);
    // Drop in-memory strokes for that page; the store CASCADE-deletes via FK.
    this.strokes = this.strokes.filter((s) => s.pageId !== pageId);
    for (const [id, s] of this.strokeIndex) {
      if (s.pageId === pageId) this.strokeIndex.delete(id);
    }
    this.store?.deletePage(pageId);
    // If we deleted the active page, fall back to the first remaining one.
    if (this.activePageId === pageId) {
      this.activePageId = this.pages[0]?.pageId ?? null;
      this.store?.setActivePageId(this.id, this.activePageId);
    }
    this.broadcast({ type: "page_deleted", userId, pageId });
    if (this.activePageId !== pageId) {
      this.broadcast({
        type: "page_selected",
        userId,
        pageId: this.activePageId ?? "",
      });
    }
  }

  // ---- Strokes — always scoped to the page they came from ----------------

  beginStroke(
    userId: string,
    header: StrokeHeader & { point: Point; pageId: string },
  ): void {
    if (!this.pages.some((p) => p.pageId === header.pageId)) return;
    const { point, pageId, ...rest } = header;
    const stroke: ActiveStroke = {
      ...rest,
      pageId,
      points: [point],
      complete: false,
    };
    this.strokes.push(stroke);
    this.strokeIndex.set(stroke.id, stroke);
    this.broadcast(
      {
        type: "stroke_start",
        userId,
        stroke: { ...rest, pageId, point },
      },
      userId,
    );
  }

  appendPoint(userId: string, strokeId: string, point: Point): void {
    const stroke = this.strokeIndex.get(strokeId);
    if (!stroke || stroke.userId !== userId || stroke.complete) return;
    stroke.points.push(point);
    this.broadcast({ type: "stroke_point", userId, strokeId, point }, userId);
  }

  endStroke(userId: string, strokeId: string): void {
    const stroke = this.strokeIndex.get(strokeId);
    if (!stroke || stroke.userId !== userId) return;
    stroke.complete = true;
    this.store?.insertStroke(this.id, stroke.pageId, stroke);
    this.strokeIndex.delete(strokeId);
    this.broadcast({ type: "stroke_end", userId, strokeId }, userId);
  }

  /// Wipes the *active* page's strokes only. Other pages are untouched.
  clearActivePageStrokes(userId: string): void {
    const pageId = this.activePageId;
    if (!pageId) return;
    this.strokes = this.strokes.filter((s) => s.pageId !== pageId);
    for (const [id, s] of this.strokeIndex) {
      if (s.pageId === pageId) this.strokeIndex.delete(id);
    }
    this.store?.clearStrokesForPage(pageId);
    this.broadcast({ type: "canvas_cleared", userId, pageId });
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
