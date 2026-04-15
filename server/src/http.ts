import type { IncomingMessage, ServerResponse } from "node:http";
import type { Store, User } from "./db.ts";

// ============================================================================
// Simple HTTP router for /auth/* and /friends/* endpoints.
// Everything speaks JSON; session token is sent as `Authorization: Bearer ...`.
// ============================================================================

export type PresenceQuery = (userId: string) => boolean;

export interface HTTPContext {
  store: Store;
  isOnline: PresenceQuery;
}

export async function handleHTTP(
  req: IncomingMessage,
  res: ServerResponse,
  ctx: HTTPContext
): Promise<boolean> {
  const url = new URL(req.url ?? "/", "http://localhost");
  const path = url.pathname;

  // Only handle POST/GET we know about; return false to let the default
  // "hello" handler run.
  if (path === "/auth/signup" && req.method === "POST") {
    return route(req, res, () => handleSignup(req, res, ctx));
  }
  if (path === "/auth/login" && req.method === "POST") {
    return route(req, res, () => handleLogin(req, res, ctx));
  }
  if (path === "/auth/logout" && req.method === "POST") {
    return route(req, res, () => handleLogout(req, res, ctx));
  }
  if (path === "/auth/me" && req.method === "GET") {
    return route(req, res, () => handleMe(req, res, ctx));
  }
  if (path === "/users/search" && req.method === "GET") {
    return route(req, res, () =>
      handleSearch(req, res, ctx, url.searchParams)
    );
  }
  if (path === "/friends" && req.method === "GET") {
    return route(req, res, () => handleListFriends(req, res, ctx));
  }
  if (path === "/friends/requests" && req.method === "GET") {
    return route(req, res, () => handleListRequests(req, res, ctx));
  }
  if (path === "/friends/request" && req.method === "POST") {
    return route(req, res, () => handleFriendRequest(req, res, ctx));
  }
  if (path === "/friends/accept" && req.method === "POST") {
    return route(req, res, () => handleFriendAccept(req, res, ctx));
  }
  if (path === "/friends/decline" && req.method === "POST") {
    return route(req, res, () => handleFriendDecline(req, res, ctx));
  }

  return false;
}

// ============================================================================
// Plumbing
// ============================================================================

async function route(
  req: IncomingMessage,
  res: ServerResponse,
  fn: () => Promise<void> | void
): Promise<boolean> {
  try {
    await fn();
  } catch (err: any) {
    // Default error envelope
    sendJSON(res, 500, { error: err?.message ?? "Server error" });
  }
  return true;
}

async function readJSONBody<T = any>(req: IncomingMessage): Promise<T> {
  return await new Promise((resolve, reject) => {
    let size = 0;
    const chunks: Buffer[] = [];
    req.on("data", (c) => {
      size += c.length;
      if (size > 2_000_000) {
        reject(new Error("Payload too large"));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      if (!raw) return resolve({} as T);
      try {
        resolve(JSON.parse(raw));
      } catch {
        reject(new Error("Invalid JSON body"));
      }
    });
    req.on("error", reject);
  });
}

function sendJSON(res: ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(payload).toString(),
  });
  res.end(payload);
}

function bearer(req: IncomingMessage): string | null {
  const h = req.headers["authorization"];
  if (!h || !h.startsWith("Bearer ")) return null;
  return h.slice(7);
}

function requireAuth(
  req: IncomingMessage,
  res: ServerResponse,
  ctx: HTTPContext
): User | null {
  const token = bearer(req);
  if (!token) {
    sendJSON(res, 401, { error: "Missing Authorization header" });
    return null;
  }
  const user = ctx.store.lookupSession(token);
  if (!user) {
    sendJSON(res, 401, { error: "Invalid or expired session" });
    return null;
  }
  return user;
}

function userDTO(u: User) {
  return { id: u.id, username: u.username, displayName: u.displayName };
}

// ============================================================================
// Rate limiting (per-IP, login + signup only)
// ============================================================================

const rateBuckets = new Map<string, { count: number; windowStart: number }>();
const RATE_LIMIT = 10;        // attempts
const RATE_WINDOW_MS = 60_000; // per minute

function rateLimit(req: IncomingMessage): boolean {
  const ip = (req.socket.remoteAddress ?? "unknown").toString();
  const now = Date.now();
  const bucket = rateBuckets.get(ip);
  if (!bucket || now - bucket.windowStart > RATE_WINDOW_MS) {
    rateBuckets.set(ip, { count: 1, windowStart: now });
    return true;
  }
  bucket.count++;
  if (bucket.count > RATE_LIMIT) return false;
  return true;
}

// ============================================================================
// Handlers
// ============================================================================

async function handleSignup(
  req: IncomingMessage,
  res: ServerResponse,
  ctx: HTTPContext
): Promise<void> {
  if (!rateLimit(req)) {
    sendJSON(res, 429, { error: "Too many attempts. Try again in a minute." });
    return;
  }
  const body = await readJSONBody<{ username?: string; password?: string }>(req);
  const username = (body.username ?? "").trim();
  const password = body.password ?? "";
  if (!username || !password) {
    sendJSON(res, 400, { error: "username and password are required" });
    return;
  }

  try {
    const user = await ctx.store.createUser({ username, password });
    const token = ctx.store.createSession(user.id);
    sendJSON(res, 200, { token, user: userDTO(user) });
  } catch (err: any) {
    const msg = err?.message ?? "Signup failed";
    // Username taken → 409 (client shows specific message)
    const status = /already taken/i.test(msg) ? 409 : 400;
    sendJSON(res, status, { error: msg });
  }
}

async function handleLogin(
  req: IncomingMessage,
  res: ServerResponse,
  ctx: HTTPContext
): Promise<void> {
  if (!rateLimit(req)) {
    sendJSON(res, 429, { error: "Too many attempts. Try again in a minute." });
    return;
  }
  const body = await readJSONBody<{ username?: string; password?: string }>(req);
  const username = (body.username ?? "").trim();
  const password = body.password ?? "";
  if (!username || !password) {
    sendJSON(res, 400, { error: "username and password are required" });
    return;
  }
  const user = await ctx.store.verifyLogin(username, password);
  if (!user) {
    sendJSON(res, 401, { error: "Incorrect username or password." });
    return;
  }
  const token = ctx.store.createSession(user.id);
  sendJSON(res, 200, { token, user: userDTO(user) });
}

async function handleLogout(
  req: IncomingMessage,
  res: ServerResponse,
  ctx: HTTPContext
): Promise<void> {
  const token = bearer(req);
  if (token) ctx.store.deleteSession(token);
  sendJSON(res, 200, { ok: true });
}

async function handleMe(
  req: IncomingMessage,
  res: ServerResponse,
  ctx: HTTPContext
): Promise<void> {
  const user = requireAuth(req, res, ctx);
  if (!user) return;
  sendJSON(res, 200, { user: userDTO(user) });
}

async function handleSearch(
  req: IncomingMessage,
  res: ServerResponse,
  ctx: HTTPContext,
  params: URLSearchParams
): Promise<void> {
  const user = requireAuth(req, res, ctx);
  if (!user) return;
  const q = (params.get("q") ?? "").trim();
  if (q.length < 2) {
    sendJSON(res, 200, { users: [] });
    return;
  }
  const results = ctx.store.findUsersMatching(q, user.id, 20);
  sendJSON(res, 200, { users: results.map(userDTO) });
}

async function handleListFriends(
  req: IncomingMessage,
  res: ServerResponse,
  ctx: HTTPContext
): Promise<void> {
  const user = requireAuth(req, res, ctx);
  if (!user) return;
  const friends = ctx.store.listFriends(user.id);
  sendJSON(res, 200, {
    friends: friends.map((f) => ({
      id: f.id,
      username: f.username,
      displayName: f.displayName,
      online: ctx.isOnline(f.id),
    })),
  });
}

async function handleListRequests(
  req: IncomingMessage,
  res: ServerResponse,
  ctx: HTTPContext
): Promise<void> {
  const user = requireAuth(req, res, ctx);
  if (!user) return;
  const pending = ctx.store.listPendingRequests(user.id);
  sendJSON(res, 200, {
    requests: pending.map((p) => ({
      requesterId: p.requesterId,
      username: p.requesterUsername,
      displayName: p.requesterDisplayName,
      createdAt: p.createdAt,
    })),
  });
}

async function handleFriendRequest(
  req: IncomingMessage,
  res: ServerResponse,
  ctx: HTTPContext
): Promise<void> {
  const user = requireAuth(req, res, ctx);
  if (!user) return;
  const body = await readJSONBody<{ username?: string }>(req);
  const otherName = (body.username ?? "").trim();
  if (!otherName) {
    sendJSON(res, 400, { error: "username is required" });
    return;
  }
  const other = ctx.store.getUserByUsername(otherName);
  if (!other) {
    sendJSON(res, 404, { error: "No user with that username." });
    return;
  }
  try {
    const status = ctx.store.requestFriendship(user.id, other.id);
    sendJSON(res, 200, { status, target: userDTO(other) });
  } catch (err: any) {
    sendJSON(res, 400, { error: err?.message ?? "Could not send request." });
  }
}

async function handleFriendAccept(
  req: IncomingMessage,
  res: ServerResponse,
  ctx: HTTPContext
): Promise<void> {
  const user = requireAuth(req, res, ctx);
  if (!user) return;
  const body = await readJSONBody<{ requesterId?: string }>(req);
  const requesterId = body.requesterId ?? "";
  if (!requesterId) {
    sendJSON(res, 400, { error: "requesterId is required" });
    return;
  }
  const ok = ctx.store.acceptFriendRequest(user.id, requesterId);
  sendJSON(res, ok ? 200 : 404, { ok });
}

async function handleFriendDecline(
  req: IncomingMessage,
  res: ServerResponse,
  ctx: HTTPContext
): Promise<void> {
  const user = requireAuth(req, res, ctx);
  if (!user) return;
  const body = await readJSONBody<{ requesterId?: string }>(req);
  const requesterId = body.requesterId ?? "";
  if (!requesterId) {
    sendJSON(res, 400, { error: "requesterId is required" });
    return;
  }
  const ok = ctx.store.declineFriendRequest(user.id, requesterId);
  sendJSON(res, ok ? 200 : 404, { ok });
}
