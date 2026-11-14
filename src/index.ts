import { DurableObject, WorkerEntrypoint } from "cloudflare:workers";

const PORT = 4000;
const INACTIVITY_TIMEOUT_MS = 10 * 60 * 1000; // 10 minutes (allows WebSocket keepalive)

// Virtual hostname the container uses to reach the D1 gateway below.
// Resolves only inside the container, via the outbound HTTP intercept.
const D1_HOSTNAME = "d1.internal";

export interface Env {
  ELIXIR_CONTAINER: DurableObjectNamespace;
  SECRET_KEY_BASE: string;
  DATABASE_URL?: string;
  PHX_HOST: string;
  DB?: D1Database;
}

type TaskRow = Record<string, unknown>;

const TASK_COLUMNS = "id, title, completed, inserted_at, updated_at";
const MESSAGE_COLUMNS = "id, room, nickname, body, inserted_at";
const MESSAGE_LIMIT_DEFAULT = 50;
const MESSAGE_LIMIT_MAX = 200;
const USER_COLUMNS = "id, email, hashed_password, confirmed_at, inserted_at, updated_at";
const USER_TOKEN_COLUMNS =
  "id, user_id, token, context, sent_to, authenticated_at, inserted_at";

// Session/magic-link token bytes travel as lowercase hex (see migration 0003).
const TOKEN_FORMAT = /^[0-9a-f]{64}$/;
// SQLite's CURRENT_TIMESTAMP format, which every timestamp column uses.
const TIMESTAMP_FORMAT = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/;
const EMAIL_MAX_LENGTH = 160;
const CONTEXT_MAX_LENGTH = 100;

/**
 * Private HTTP gateway that lets the container read and write the Worker's
 * `DB` D1 binding without exposing the database to the public internet.
 * Only reachable inside the container, via the `d1.internal` outbound
 * intercept registered in `startAndWait()` below.
 *
 * Routes:
 *   GET    /tasks      -> {tasks: [row]}
 *   POST   /tasks      -> 201 {task: row}   body: {title}
 *   GET    /tasks/:id  -> {task: row} | 404
 *   PATCH  /tasks/:id  -> {task: row}       body: {title?, completed?}
 *   DELETE /tasks/:id  -> {deleted: true} | 404
 *   GET    /messages?room=&limit= -> {messages: [row]}  (oldest first)
 *   POST   /messages   -> 201 {message: row}  body: {room, nickname, body}
 *   GET    /users?email=  -> {user: row} | 404   (email matched case-insensitively)
 *   GET    /users/:id  -> {user: row} | 404
 *   POST   /users      -> 201 {user: row} | 409  body: {email, hashed_password?,
 *                                                       confirmed_at?}
 *   PATCH  /users/:id  -> {user: row, expired_tokens: [row]} | 404 | 409
 *                        body: {email?, hashed_password?, confirmed_at?,
 *                               delete_all_tokens?, delete_tokens_context?}
 *   POST   /user_tokens -> 201 {user_token: row}  body: {user_id, token, context,
 *                                                        sent_to?, authenticated_at?}
 *   GET    /user_tokens?token=&context= -> {user_token: row, user: row} | 404
 *   DELETE /user_tokens?token=&context= -> {deleted: count}
 *
 * Token expiry is deliberately *not* enforced here: the validity windows live
 * in `App.Accounts.UserToken`, where `mix phx.gen.auth` put them, and
 * `App.Accounts` applies them to the `inserted_at` this gateway returns.
 *
 * All SQL is parameterized; no user input is ever interpolated into a query.
 * The one piece of SQL built at runtime is the `SET` list of `PATCH /users/:id`,
 * assembled from a fixed allowlist of column names — values stay bound.
 */
export class D1Gateway extends WorkerEntrypoint<Env> {
  async fetch(request: Request): Promise<Response> {
    const db = this.env.DB;
    if (!db) {
      return Response.json({ error: "D1 binding not configured" }, { status: 503 });
    }

    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);
    const [collection, member] = parts;
    const isCollection = parts.length === 1;
    const isItem = parts.length === 2;

    try {
      if (isCollection && collection === "messages") {
        if (request.method === "GET") return await this.listMessages(db, url);
        if (request.method === "POST") return await this.createMessage(db, request);
        return methodNotAllowed();
      }

      if (isCollection && collection === "user_tokens") {
        if (request.method === "GET") return await this.getUserToken(db, url);
        if (request.method === "POST") return await this.createUserToken(db, request);
        if (request.method === "DELETE") return await this.deleteUserToken(db, url);
        return methodNotAllowed();
      }

      if (isCollection && collection === "users") {
        if (request.method === "GET") return await this.getUserByEmail(db, url);
        if (request.method === "POST") return await this.createUser(db, request);
        return methodNotAllowed();
      }

      if (isItem && collection === "users") {
        const userId = readId(member);
        if (userId === null) {
          return Response.json({ error: "invalid user id" }, { status: 400 });
        }
        if (request.method === "GET") return await this.getUser(db, userId);
        if (request.method === "PATCH") return await this.updateUser(db, userId, request);
        return methodNotAllowed();
      }

      if (isCollection && collection === "tasks") {
        if (request.method === "GET") return await this.listTasks(db);
        if (request.method === "POST") return await this.createTask(db, request);
        return methodNotAllowed();
      }

      if (isItem && collection === "tasks") {
        const id = readId(member);
        if (id === null) {
          return Response.json({ error: "invalid task id" }, { status: 400 });
        }

        if (request.method === "GET") return await this.getTask(db, id);
        if (request.method === "PATCH") return await this.updateTask(db, id, request);
        if (request.method === "DELETE") return await this.deleteTask(db, id);
        return methodNotAllowed();
      }

      return Response.json({ error: "not found" }, { status: 404 });
    } catch (error) {
      if (isUniqueViolation(error)) {
        return Response.json({ error: "email has already been taken" }, { status: 409 });
      }
      console.error("D1Gateway error:", error);
      return Response.json({ error: "database error" }, { status: 500 });
    }
  }

  private async getUserByEmail(db: D1Database, url: URL): Promise<Response> {
    const email = readText(url.searchParams.get("email"), EMAIL_MAX_LENGTH);
    if (email === null) {
      return Response.json({ error: "email is required" }, { status: 400 });
    }

    // Stands in for Postgres citext: see the unique index on lower(email).
    const row = await firstRow(
      db.prepare(`SELECT ${USER_COLUMNS} FROM users WHERE lower(email) = lower(?1)`).bind(email),
    );
    return row ? Response.json({ user: row }) : notFound();
  }

  private async getUser(db: D1Database, id: number): Promise<Response> {
    const row = await firstRow(
      db.prepare(`SELECT ${USER_COLUMNS} FROM users WHERE id = ?1`).bind(id),
    );
    return row ? Response.json({ user: row }) : notFound();
  }

  private async createUser(db: D1Database, request: Request): Promise<Response> {
    const payload = await readJson(request);
    const email = readText(payload.email, EMAIL_MAX_LENGTH);
    const hashedPassword = readOptionalText(payload.hashed_password, 255);
    const confirmedAt = readOptionalTimestamp(payload.confirmed_at);

    if (email === null || hashedPassword === null || confirmedAt === null) {
      return Response.json({ error: "invalid user attributes" }, { status: 400 });
    }

    const row = await firstRow(
      db
        .prepare(
          `INSERT INTO users (email, hashed_password, confirmed_at) ` +
            `VALUES (?1, ?2, ?3) RETURNING ${USER_COLUMNS}`,
        )
        .bind(email, hashedPassword, confirmedAt),
    );
    return Response.json({ user: row }, { status: 201 });
  }

  /**
   * Updates a user and, optionally, expires their tokens in the same D1 batch.
   *
   * A batch is a single implicit transaction, which is what keeps
   * `App.Accounts.update_user_password/2` atomic the way the generator's
   * `Repo.transact/1` was: the new password and the expired sessions land
   * together or not at all.
   */
  private async updateUser(db: D1Database, id: number, request: Request): Promise<Response> {
    const payload = await readJson(request);
    const columns: string[] = [];
    const values: (string | null)[] = [];

    if (payload.email !== undefined) {
      const email = readText(payload.email, EMAIL_MAX_LENGTH);
      if (email === null) return Response.json({ error: "invalid email" }, { status: 400 });
      columns.push("email");
      values.push(email);
    }

    if (payload.hashed_password !== undefined) {
      const hashedPassword = readText(payload.hashed_password, 255);
      if (hashedPassword === null) {
        return Response.json({ error: "invalid hashed_password" }, { status: 400 });
      }
      columns.push("hashed_password");
      values.push(hashedPassword);
    }

    if (payload.confirmed_at !== undefined) {
      const confirmedAt = readTimestamp(payload.confirmed_at);
      if (confirmedAt === null) {
        return Response.json({ error: "invalid confirmed_at" }, { status: 400 });
      }
      columns.push("confirmed_at");
      values.push(confirmedAt);
    }

    if (columns.length === 0) {
      return Response.json({ error: "no user attributes to update" }, { status: 400 });
    }

    const deleteContext =
      payload.delete_tokens_context === undefined
        ? undefined
        : readText(payload.delete_tokens_context, CONTEXT_MAX_LENGTH);
    if (deleteContext === null) {
      return Response.json({ error: "invalid delete_tokens_context" }, { status: 400 });
    }

    // Column names come from the allowlist above, never from the payload.
    const assignments = columns.map((column, index) => `${column} = ?${index + 1}`).join(", ");
    const statements = [
      db
        .prepare(
          `UPDATE users SET ${assignments}, updated_at = CURRENT_TIMESTAMP ` +
            `WHERE id = ?${columns.length + 1} RETURNING ${USER_COLUMNS}`,
        )
        .bind(...values, id),
    ];

    if (payload.delete_all_tokens === true) {
      statements.push(
        db
          .prepare(`DELETE FROM users_tokens WHERE user_id = ?1 RETURNING ${USER_TOKEN_COLUMNS}`)
          .bind(id),
      );
    } else if (deleteContext !== undefined) {
      statements.push(
        db
          .prepare(
            `DELETE FROM users_tokens WHERE user_id = ?1 AND context = ?2 ` +
              `RETURNING ${USER_TOKEN_COLUMNS}`,
          )
          .bind(id, deleteContext),
      );
    }

    const results = await db.batch<TaskRow>(statements);
    const user = results[0]?.results?.[0] ?? null;
    if (!user) return notFound();

    return Response.json({ user, expired_tokens: results[1]?.results ?? [] });
  }

  private async createUserToken(db: D1Database, request: Request): Promise<Response> {
    const payload = await readJson(request);
    const userId = readId(payload.user_id);
    const token = readToken(payload.token);
    const context = readText(payload.context, CONTEXT_MAX_LENGTH);
    const sentTo = readOptionalText(payload.sent_to, EMAIL_MAX_LENGTH);
    const authenticatedAt = readOptionalTimestamp(payload.authenticated_at);

    if (
      userId === null ||
      token === null ||
      context === null ||
      sentTo === null ||
      authenticatedAt === null
    ) {
      return Response.json({ error: "invalid token attributes" }, { status: 400 });
    }

    const row = await firstRow(
      db
        .prepare(
          `INSERT INTO users_tokens (user_id, token, context, sent_to, authenticated_at) ` +
            `VALUES (?1, ?2, ?3, ?4, ?5) RETURNING ${USER_TOKEN_COLUMNS}`,
        )
        .bind(userId, token, context, sentTo, authenticatedAt),
    );
    return Response.json({ user_token: row }, { status: 201 });
  }

  private async getUserToken(db: D1Database, url: URL): Promise<Response> {
    const token = readToken(url.searchParams.get("token"));
    const context = readText(url.searchParams.get("context"), CONTEXT_MAX_LENGTH);
    if (token === null || context === null) {
      return Response.json({ error: "token and context are required" }, { status: 400 });
    }

    const userToken = await firstRow(
      db
        .prepare(
          `SELECT ${USER_TOKEN_COLUMNS} FROM users_tokens WHERE context = ?1 AND token = ?2`,
        )
        .bind(context, token),
    );
    if (!userToken) return notFound();

    const user = await firstRow(
      db.prepare(`SELECT ${USER_COLUMNS} FROM users WHERE id = ?1`).bind(userToken.user_id),
    );
    if (!user) return notFound();

    return Response.json({ user_token: userToken, user });
  }

  private async deleteUserToken(db: D1Database, url: URL): Promise<Response> {
    const token = readToken(url.searchParams.get("token"));
    const context = readText(url.searchParams.get("context"), CONTEXT_MAX_LENGTH);
    if (token === null || context === null) {
      return Response.json({ error: "token and context are required" }, { status: 400 });
    }

    const result = await db
      .prepare("DELETE FROM users_tokens WHERE context = ?1 AND token = ?2 RETURNING id")
      .bind(context, token)
      .run<TaskRow>();
    return Response.json({ deleted: result.results?.length ?? 0 });
  }

  private async listMessages(db: D1Database, url: URL): Promise<Response> {
    const room = (url.searchParams.get("room") ?? "").trim();
    if (!room) {
      return Response.json({ error: "room is required" }, { status: 400 });
    }

    const requested = Number(url.searchParams.get("limit") ?? MESSAGE_LIMIT_DEFAULT);
    const limit =
      Number.isInteger(requested) && requested >= 1
        ? Math.min(requested, MESSAGE_LIMIT_MAX)
        : MESSAGE_LIMIT_DEFAULT;

    // Take the newest `limit` rows, then flip to chronological order so the
    // client can append straight into the transcript.
    const result = await db
      .prepare(
        `SELECT ${MESSAGE_COLUMNS} FROM messages WHERE room = ?1 ` +
          `ORDER BY id DESC LIMIT ?2`,
      )
      .bind(room, limit)
      .all<TaskRow>();
    return Response.json({ messages: (result.results ?? []).reverse() });
  }

  private async createMessage(db: D1Database, request: Request): Promise<Response> {
    const payload = await readJson(request);
    const room = readText(payload.room, 64);
    const nickname = readText(payload.nickname, 64);
    const body = readText(payload.body, 2000);

    if (room === null || nickname === null || body === null) {
      return Response.json(
        { error: "room, nickname and body must be non-empty strings within their length limits" },
        { status: 400 },
      );
    }

    const row = await firstRow(
      db
        .prepare(
          `INSERT INTO messages (room, nickname, body) VALUES (?1, ?2, ?3) ` +
            `RETURNING ${MESSAGE_COLUMNS}`,
        )
        .bind(room, nickname, body),
    );
    return Response.json({ message: row }, { status: 201 });
  }

  private async listTasks(db: D1Database): Promise<Response> {
    const result = await db
      .prepare(`SELECT ${TASK_COLUMNS} FROM tasks ORDER BY inserted_at DESC, id DESC`)
      .all<TaskRow>();
    return Response.json({ tasks: result.results });
  }

  private async createTask(db: D1Database, request: Request): Promise<Response> {
    const body = await readJson(request);
    const title = readTitle(body);
    if (title === null) {
      return Response.json(
        { error: "title must be a non-empty string of at most 255 characters" },
        { status: 400 },
      );
    }

    const row = await firstRow(
      db
        .prepare(`INSERT INTO tasks (title, completed) VALUES (?1, 0) RETURNING ${TASK_COLUMNS}`)
        .bind(title),
    );
    return Response.json({ task: row }, { status: 201 });
  }

  private async getTask(db: D1Database, id: number): Promise<Response> {
    const row = await firstRow(
      db.prepare(`SELECT ${TASK_COLUMNS} FROM tasks WHERE id = ?1`).bind(id),
    );
    return row
      ? Response.json({ task: row })
      : Response.json({ error: "not found" }, { status: 404 });
  }

  private async updateTask(
    db: D1Database,
    id: number,
    request: Request,
  ): Promise<Response> {
    const body = await readJson(request);
    const current = await firstRow(
      db.prepare(`SELECT ${TASK_COLUMNS} FROM tasks WHERE id = ?1`).bind(id),
    );
    if (!current) {
      return Response.json({ error: "not found" }, { status: 404 });
    }

    let title = String(current.title ?? "");
    if (body.title !== undefined) {
      const parsed = readTitle(body);
      if (parsed === null) {
        return Response.json(
          { error: "title must be a non-empty string of at most 255 characters" },
          { status: 400 },
        );
      }
      title = parsed;
    }

    let completed = current.completed === 1 || current.completed === true;
    if (body.completed !== undefined) {
      completed = Boolean(body.completed);
    }

    const row = await firstRow(
      db
        .prepare(
          `UPDATE tasks SET title = ?1, completed = ?2, updated_at = CURRENT_TIMESTAMP ` +
            `WHERE id = ?3 RETURNING ${TASK_COLUMNS}`,
        )
        .bind(title, completed ? 1 : 0, id),
    );
    return Response.json({ task: row });
  }

  private async deleteTask(db: D1Database, id: number): Promise<Response> {
    const row = await firstRow(
      db.prepare("DELETE FROM tasks WHERE id = ?1 RETURNING id").bind(id),
    );
    return row
      ? Response.json({ deleted: true })
      : Response.json({ error: "not found" }, { status: 404 });
  }
}

function methodNotAllowed(): Response {
  return Response.json({ error: "method not allowed" }, { status: 405 });
}

function notFound(): Response {
  return Response.json({ error: "not found" }, { status: 404 });
}

/**
 * True for a violation of `users_email_idx`, which `App.Accounts` turns back
 * into a changeset error on `:email`. D1 surfaces these as plain errors, so
 * the message is all there is to match on.
 */
function isUniqueViolation(error: unknown): boolean {
  return error instanceof Error && error.message.includes("UNIQUE constraint failed");
}

async function readJson(request: Request): Promise<Record<string, unknown>> {
  try {
    const body = await request.json();
    return body && typeof body === "object" ? (body as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

function readTitle(body: Record<string, unknown>): string | null {
  if (typeof body.title !== "string") return null;
  const title = body.title.trim();
  return title.length >= 1 && title.length <= 255 ? title : null;
}

function readText(value: unknown, maxLength: number): string | null {
  if (typeof value !== "string") return null;
  const text = value.trim();
  return text.length >= 1 && text.length <= maxLength ? text : null;
}

/**
 * The helpers below all use `null` for "invalid" and `undefined` for "absent",
 * so a caller can tell a rejected value from one that was never sent.
 */
function readOptionalText(value: unknown, maxLength: number): string | null | undefined {
  if (value === undefined || value === null) return undefined;
  return readText(value, maxLength);
}

function readTimestamp(value: unknown): string | null {
  if (typeof value !== "string" || !TIMESTAMP_FORMAT.test(value)) return null;
  return value;
}

function readOptionalTimestamp(value: unknown): string | null | undefined {
  if (value === undefined || value === null) return undefined;
  return readTimestamp(value);
}

function readToken(value: unknown): string | null {
  if (typeof value !== "string" || !TOKEN_FORMAT.test(value)) return null;
  return value;
}

function readId(value: unknown): number | null {
  const id = Number(value);
  return Number.isInteger(id) && id >= 1 ? id : null;
}

async function firstRow(statement: D1PreparedStatement): Promise<TaskRow | null> {
  const result = await statement.run<TaskRow>();
  return result.results?.[0] ?? null;
}

export class ElixirContainer extends DurableObject<Env> {
  private starting: Promise<void> | undefined;
  private monitoring: Promise<void> | undefined;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    const container = ctx.container;
    if (container?.running) {
      void ctx.blockConcurrencyWhile(() =>
        container.setInactivityTimeout(INACTIVITY_TIMEOUT_MS),
      );
      this.observeExit();
    }
  }

  async fetch(request: Request): Promise<Response> {
    this.starting ??= this.startAndWait().finally(() => {
      this.starting = undefined;
    });
    await this.starting;

    // Forward the request to the container, preserving all headers
    // (including Upgrade/Connection for WebSocket support)
    const url = new URL(request.url);
    url.protocol = "http:";
    url.host = "container";

    const headers = new Headers(request.headers);
    // Ensure Phoenix knows the original request was HTTPS (for force_ssl)
    if (!headers.has("x-forwarded-proto")) {
      headers.set("x-forwarded-proto", "https");
    }

    const forwarded = new Request(url, {
      method: request.method,
      headers,
      body: request.body,
      // @ts-expect-error - duplex is needed for streaming request bodies
      duplex: "half",
    });

    return this.ctx.container!.getTcpPort(PORT).fetch(forwarded);
  }

  private getContainerEnv(): Record<string, string> {
    const env: Record<string, string> = {
      PHX_SERVER: "true",
      SECRET_KEY_BASE: this.env.SECRET_KEY_BASE,
      PHX_HOST: this.env.PHX_HOST,
      PORT: String(PORT),
    };
    if (this.env.DATABASE_URL) {
      env.DATABASE_URL = this.env.DATABASE_URL;
    }
    return env;
  }

  private async startAndWait(): Promise<void> {
    const container = this.ctx.container!;
    if (!container.running) {
      if (this.env.DB) {
        // Private D1 gateway for the container (see D1Gateway above).
        // Register before start(); intercepts last until the container stops.
        await container.interceptOutboundHttp(
          D1_HOSTNAME,
          this.ctx.exports.D1Gateway({ props: {} }),
        );
      }
      container.start({
        image: container.images.base,
        instance: "basic",
        enableInternet: true,
        env: this.getContainerEnv(),
      });
    }
    this.observeExit();
    await container.setInactivityTimeout(INACTIVITY_TIMEOUT_MS);

    // Poll the health endpoint until the container is ready
    const port = container.getTcpPort(PORT);
    for (let attempt = 0; attempt < 100; attempt++) {
      try {
        const res = await port.fetch("http://container/health", {
          headers: { "x-forwarded-proto": "https" },
          signal: AbortSignal.timeout(2000),
        });
        await res.body?.cancel();
        if (res.ok) return;
      } catch {
        // Port not listening yet — retry
      }
      await scheduler.wait(300);
    }
    throw new Error("Elixir container did not become ready on port " + PORT);
  }

  private observeExit(): void {
    if (this.monitoring) return;
    this.monitoring = this.ctx
      .container!.monitor()
      .then(() => console.log("Container exited successfully"))
      .catch((error: unknown) => console.error("Container failed:", error))
      .finally(() => {
        this.monitoring = undefined;
      });
    this.ctx.waitUntil(this.monitoring);
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return env.ELIXIR_CONTAINER.getByName("singleton").fetch(request);
  },
};
