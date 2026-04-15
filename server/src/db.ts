import Database from "better-sqlite3";
import bcrypt from "bcrypt";
import { randomUUID, randomBytes } from "node:crypto";
import type { Color, Page, Stroke, Tool } from "./protocol.ts";

// ============================================================================
// Types returned by the store
// ============================================================================

export interface User {
  id: string;
  username: string;            // normalized lowercase
  displayName: string;         // as originally typed
  createdAt: number;
}

export interface PendingRequest {
  requesterId: string;
  requesterUsername: string;
  requesterDisplayName: string;
  createdAt: number;
}

export interface FriendRow {
  id: string;
  username: string;
  displayName: string;
  friendshipCreatedAt: number;
}

// ============================================================================
// Store interface
// ============================================================================

export interface Store {
  // Auth
  createUser(input: { username: string; password: string }): Promise<User>;
  getUserByUsername(username: string): User | null;
  getUserById(id: string): User | null;
  verifyLogin(username: string, password: string): Promise<User | null>;

  createSession(userId: string): string;     // returns opaque token
  lookupSession(token: string): User | null; // returns user if token valid
  deleteSession(token: string): void;

  // Friends
  findUsersMatching(query: string, excludeUserId: string, limit: number): User[];
  /**
   * Idempotent friend request. Returns the resulting status.
   * - If A→B doesn't exist and B→A doesn't either: inserts A→B pending.
   * - If A→B already pending: no-op, returns 'pending'.
   * - If B→A is pending: auto-accepts (both sides become friends).
   * - If already accepted: no-op, returns 'accepted'.
   * - If self-request: throws.
   */
  requestFriendship(fromUserId: string, toUserId: string): "pending" | "accepted";
  acceptFriendRequest(accepterId: string, requesterId: string): boolean;
  declineFriendRequest(accepterId: string, requesterId: string): boolean;
  listFriends(userId: string): FriendRow[];
  listPendingRequests(userId: string): PendingRequest[];
  areFriends(a: string, b: string): boolean;

  // Rooms / strokes (unchanged semantics from before)
  ensureRoom(id: string): void;
  touchRoom(id: string): void;
  getPage(id: string): Page | null;
  setPage(id: string, page: Page | null): void;
  loadStrokes(roomId: string): Stroke[];
  insertStroke(roomId: string, stroke: Stroke): void;
  clearStrokes(roomId: string): void;

  close(): void;
}

// ============================================================================
// Migrations
// ============================================================================

const MIGRATIONS: Array<(db: Database.Database) => void> = [
  // v1: rooms + strokes
  (db) => {
    db.exec(`
      CREATE TABLE IF NOT EXISTS rooms (
        id TEXT PRIMARY KEY,
        created_at INTEGER NOT NULL,
        last_active_at INTEGER NOT NULL,
        current_page_id TEXT,
        current_page_name TEXT,
        current_page_mime TEXT,
        current_page_bytes BLOB
      );
      CREATE TABLE IF NOT EXISTS strokes (
        id TEXT PRIMARY KEY,
        room_id TEXT NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
        user_id TEXT NOT NULL,
        tool TEXT NOT NULL,
        color_r REAL NOT NULL,
        color_g REAL NOT NULL,
        color_b REAL NOT NULL,
        color_a REAL NOT NULL,
        brush_size REAL NOT NULL,
        points_json TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_strokes_room_time
        ON strokes(room_id, created_at);
    `);
  },

  // v2: users + sessions + friendships
  (db) => {
    db.exec(`
      CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY,
        username TEXT UNIQUE NOT NULL,
        display_name TEXT NOT NULL,
        password_hash TEXT NOT NULL,
        created_at INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS sessions (
        token TEXT PRIMARY KEY,
        user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        created_at INTEGER NOT NULL,
        last_used_at INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);
      CREATE TABLE IF NOT EXISTS friendships (
        requester_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        addressee_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        status TEXT NOT NULL CHECK (status IN ('pending', 'accepted')),
        created_at INTEGER NOT NULL,
        PRIMARY KEY (requester_id, addressee_id)
      );
      CREATE INDEX IF NOT EXISTS idx_friendships_addressee
        ON friendships(addressee_id, status);
    `);
  },
];

function migrate(db: Database.Database): void {
  const current = db.pragma("user_version", { simple: true }) as number;
  for (let v = current; v < MIGRATIONS.length; v++) {
    const fn = MIGRATIONS[v]!;
    db.transaction(() => {
      fn(db);
      db.pragma(`user_version = ${v + 1}`);
    })();
  }
}

// ============================================================================
// Validation
// ============================================================================

const USERNAME_RE = /^[a-zA-Z0-9_]{3,20}$/;
const MIN_PASSWORD_LEN = 8;

export function validateUsername(username: string): string | null {
  if (!USERNAME_RE.test(username)) {
    return "Username must be 3–20 chars, letters / numbers / underscore only.";
  }
  return null;
}

export function validatePassword(password: string): string | null {
  if (password.length < MIN_PASSWORD_LEN) {
    return `Password must be at least ${MIN_PASSWORD_LEN} characters.`;
  }
  return null;
}

// ============================================================================
// Row types (internal)
// ============================================================================

type UserRow = {
  id: string;
  username: string;
  display_name: string;
  password_hash: string;
  created_at: number;
};

type SessionRow = {
  token: string;
  user_id: string;
  created_at: number;
  last_used_at: number;
};

type RoomRow = {
  id: string;
  current_page_id: string | null;
  current_page_name: string | null;
  current_page_mime: string | null;
  current_page_bytes: Buffer | null;
};

type StrokeRow = {
  id: string;
  user_id: string;
  tool: string;
  color_r: number;
  color_g: number;
  color_b: number;
  color_a: number;
  brush_size: number;
  points_json: string;
  created_at: number;
};

type FriendshipRow = {
  requester_id: string;
  addressee_id: string;
  status: "pending" | "accepted";
  created_at: number;
};

function toUser(row: UserRow): User {
  return {
    id: row.id,
    username: row.username,
    displayName: row.display_name,
    createdAt: row.created_at,
  };
}

// ============================================================================
// Store implementation
// ============================================================================

export function openStore(dbPath: string): Store {
  const db = new Database(dbPath);
  db.pragma("journal_mode = WAL");
  db.pragma("synchronous = NORMAL");
  db.pragma("foreign_keys = ON");
  migrate(db);

  // ---- Users / sessions -----
  const stmts = {
    insertUser: db.prepare(
      `INSERT INTO users (id, username, display_name, password_hash, created_at)
       VALUES (?, ?, ?, ?, ?)`
    ),
    getUserById: db.prepare(`SELECT * FROM users WHERE id = ?`),
    getUserByUsername: db.prepare(
      `SELECT * FROM users WHERE username = ?`
    ),
    searchUsers: db.prepare(
      `SELECT * FROM users
         WHERE username LIKE ? AND id != ?
         ORDER BY username
         LIMIT ?`
    ),

    insertSession: db.prepare(
      `INSERT INTO sessions (token, user_id, created_at, last_used_at)
       VALUES (?, ?, ?, ?)`
    ),
    lookupSession: db.prepare(
      `SELECT s.*, u.id AS uid, u.username AS uname,
              u.display_name AS udn, u.created_at AS ucreated
         FROM sessions s
         JOIN users u ON u.id = s.user_id
         WHERE s.token = ?`
    ),
    touchSession: db.prepare(
      `UPDATE sessions SET last_used_at = ? WHERE token = ?`
    ),
    deleteSession: db.prepare(`DELETE FROM sessions WHERE token = ?`),

    // Friendships
    getFriendship: db.prepare(
      `SELECT * FROM friendships
        WHERE requester_id = ? AND addressee_id = ?`
    ),
    insertFriendship: db.prepare(
      `INSERT INTO friendships (requester_id, addressee_id, status, created_at)
       VALUES (?, ?, 'pending', ?)`
    ),
    acceptFriendship: db.prepare(
      `UPDATE friendships
          SET status = 'accepted'
        WHERE requester_id = ? AND addressee_id = ? AND status = 'pending'`
    ),
    deleteFriendship: db.prepare(
      `DELETE FROM friendships
        WHERE requester_id = ? AND addressee_id = ?`
    ),
    listAcceptedFriends: db.prepare(
      `SELECT u.id AS id,
              u.username AS username,
              u.display_name AS displayName,
              f.created_at AS friendshipCreatedAt
         FROM friendships f
         JOIN users u ON (
              (f.requester_id = ? AND u.id = f.addressee_id) OR
              (f.addressee_id = ? AND u.id = f.requester_id)
         )
        WHERE f.status = 'accepted'
        ORDER BY u.username`
    ),
    listPending: db.prepare(
      `SELECT u.id AS id,
              u.username AS username,
              u.display_name AS display_name,
              f.created_at AS created_at
         FROM friendships f
         JOIN users u ON u.id = f.requester_id
        WHERE f.addressee_id = ? AND f.status = 'pending'
        ORDER BY f.created_at`
    ),
    areFriendsQ: db.prepare(
      `SELECT 1 FROM friendships
        WHERE status = 'accepted'
          AND ((requester_id = ? AND addressee_id = ?)
            OR (requester_id = ? AND addressee_id = ?))
        LIMIT 1`
    ),

    // Rooms
    ensureRoom: db.prepare(
      `INSERT OR IGNORE INTO rooms (id, created_at, last_active_at)
       VALUES (?, ?, ?)`
    ),
    touchRoom: db.prepare(`UPDATE rooms SET last_active_at = ? WHERE id = ?`),
    getRoom: db.prepare(`SELECT * FROM rooms WHERE id = ?`),
    setPage: db.prepare(
      `UPDATE rooms
         SET current_page_id = ?, current_page_name = ?,
             current_page_mime = ?, current_page_bytes = ?,
             last_active_at = ?
       WHERE id = ?`
    ),
    loadStrokes: db.prepare(
      `SELECT * FROM strokes WHERE room_id = ? ORDER BY created_at ASC`
    ),
    insertStroke: db.prepare(
      `INSERT OR REPLACE INTO strokes
         (id, room_id, user_id, tool,
          color_r, color_g, color_b, color_a,
          brush_size, points_json, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    ),
    clearStrokes: db.prepare(`DELETE FROM strokes WHERE room_id = ?`),
  };

  const now = () => Date.now();
  const newToken = () => randomBytes(32).toString("hex");

  const store: Store = {
    async createUser({ username, password }) {
      const vU = validateUsername(username);
      if (vU) throw new Error(vU);
      const vP = validatePassword(password);
      if (vP) throw new Error(vP);

      const normalized = username.toLowerCase();
      const hash = await bcrypt.hash(password, 10);
      const id = randomUUID();

      try {
        stmts.insertUser.run(id, normalized, username, hash, now());
      } catch (err: any) {
        if (String(err?.code) === "SQLITE_CONSTRAINT_UNIQUE") {
          throw new Error("Username already taken.");
        }
        throw err;
      }
      return {
        id,
        username: normalized,
        displayName: username,
        createdAt: now(),
      };
    },

    getUserByUsername(username) {
      const row = stmts.getUserByUsername.get(
        username.toLowerCase()
      ) as UserRow | undefined;
      return row ? toUser(row) : null;
    },
    getUserById(id) {
      const row = stmts.getUserById.get(id) as UserRow | undefined;
      return row ? toUser(row) : null;
    },
    async verifyLogin(username, password) {
      const row = stmts.getUserByUsername.get(
        username.toLowerCase()
      ) as UserRow | undefined;
      if (!row) return null;
      const ok = await bcrypt.compare(password, row.password_hash);
      return ok ? toUser(row) : null;
    },

    createSession(userId) {
      const token = newToken();
      const t = now();
      stmts.insertSession.run(token, userId, t, t);
      return token;
    },
    lookupSession(token) {
      const row = stmts.lookupSession.get(token) as
        | (SessionRow & {
            uid: string;
            uname: string;
            udn: string;
            ucreated: number;
          })
        | undefined;
      if (!row) return null;
      // Touch session asynchronously; not critical if it fails.
      try {
        stmts.touchSession.run(now(), token);
      } catch { /* ignore */ }
      return {
        id: row.uid,
        username: row.uname,
        displayName: row.udn,
        createdAt: row.ucreated,
      };
    },
    deleteSession(token) {
      stmts.deleteSession.run(token);
    },

    findUsersMatching(query, excludeUserId, limit) {
      const needle = `%${query.toLowerCase()}%`;
      const rows = stmts.searchUsers.all(
        needle, excludeUserId, limit
      ) as UserRow[];
      return rows.map(toUser);
    },

    requestFriendship(fromUserId, toUserId) {
      if (fromUserId === toUserId) {
        throw new Error("Can't friend yourself.");
      }
      return db.transaction(() => {
        const existingA = stmts.getFriendship.get(fromUserId, toUserId) as
          | FriendshipRow
          | undefined;
        if (existingA?.status === "accepted") return "accepted";
        if (existingA?.status === "pending") return "pending";

        const existingB = stmts.getFriendship.get(toUserId, fromUserId) as
          | FriendshipRow
          | undefined;
        if (existingB?.status === "accepted") return "accepted";
        if (existingB?.status === "pending") {
          // Reverse request exists — auto-accept.
          stmts.acceptFriendship.run(toUserId, fromUserId);
          return "accepted";
        }
        stmts.insertFriendship.run(fromUserId, toUserId, now());
        return "pending";
      })();
    },
    acceptFriendRequest(accepterId, requesterId) {
      const res = stmts.acceptFriendship.run(requesterId, accepterId);
      return res.changes > 0;
    },
    declineFriendRequest(accepterId, requesterId) {
      const res = stmts.deleteFriendship.run(requesterId, accepterId);
      return res.changes > 0;
    },
    listFriends(userId) {
      return stmts.listAcceptedFriends.all(userId, userId) as FriendRow[];
    },
    listPendingRequests(userId) {
      type R = {
        id: string; username: string; display_name: string; created_at: number;
      };
      const rows = stmts.listPending.all(userId) as R[];
      return rows.map((r) => ({
        requesterId: r.id,
        requesterUsername: r.username,
        requesterDisplayName: r.display_name,
        createdAt: r.created_at,
      }));
    },
    areFriends(a, b) {
      const row = stmts.areFriendsQ.get(a, b, b, a);
      return !!row;
    },

    // --- Rooms / strokes ---

    ensureRoom(id) {
      stmts.ensureRoom.run(id, now(), now());
    },
    touchRoom(id) {
      stmts.touchRoom.run(now(), id);
    },
    getPage(id) {
      const row = stmts.getRoom.get(id) as RoomRow | undefined;
      if (!row || !row.current_page_id) return null;
      return {
        pageId: row.current_page_id,
        displayName: row.current_page_name ?? "",
        mimeType: row.current_page_mime ?? "image/png",
        imageBase64: row.current_page_bytes
          ? row.current_page_bytes.toString("base64")
          : "",
      };
    },
    setPage(id, page) {
      const bytes =
        page && page.imageBase64
          ? Buffer.from(page.imageBase64, "base64")
          : null;
      stmts.setPage.run(
        page?.pageId ?? null,
        page?.displayName ?? null,
        page?.mimeType ?? null,
        bytes,
        now(),
        id
      );
    },
    loadStrokes(roomId) {
      const rows = stmts.loadStrokes.all(roomId) as StrokeRow[];
      return rows.map((r) => ({
        id: r.id,
        userId: r.user_id,
        tool: r.tool as Tool,
        color: {
          r: r.color_r, g: r.color_g, b: r.color_b, a: r.color_a,
        } satisfies Color,
        brushSize: r.brush_size,
        points: JSON.parse(r.points_json) as Stroke["points"],
        complete: true,
      }));
    },
    insertStroke(roomId, stroke) {
      stmts.insertStroke.run(
        stroke.id,
        roomId,
        stroke.userId,
        stroke.tool,
        stroke.color.r,
        stroke.color.g,
        stroke.color.b,
        stroke.color.a,
        stroke.brushSize,
        JSON.stringify(stroke.points),
        now()
      );
    },
    clearStrokes(roomId) {
      stmts.clearStrokes.run(roomId);
    },
    close() {
      db.close();
    },
  };

  return store;
}

// Re-export RoomStore alias for backwards compat.
export type RoomStore = Store;
