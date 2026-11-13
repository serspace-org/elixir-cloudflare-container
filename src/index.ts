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
 *
 * All SQL is parameterized; no user input is ever interpolated into a query.
 */
export class D1Gateway extends WorkerEntrypoint<Env> {
  async fetch(request: Request): Promise<Response> {
    const db = this.env.DB;
    if (!db) {
      return Response.json({ error: "D1 binding not configured" }, { status: 503 });
    }

    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean);
    const isCollection = parts.length === 1 && parts[0] === "tasks";
    const isItem = parts.length === 2 && parts[0] === "tasks";

    if (!isCollection && !isItem) {
      return Response.json({ error: "not found" }, { status: 404 });
    }

    try {
      if (isCollection) {
        if (request.method === "GET") return await this.listTasks(db);
        if (request.method === "POST") return await this.createTask(db, request);
        return methodNotAllowed();
      }

      const id = Number(parts[1]);
      if (!Number.isInteger(id) || id < 1) {
        return Response.json({ error: "invalid task id" }, { status: 400 });
      }

      if (request.method === "GET") return await this.getTask(db, id);
      if (request.method === "PATCH") return await this.updateTask(db, id, request);
      if (request.method === "DELETE") return await this.deleteTask(db, id);
      return methodNotAllowed();
    } catch (error) {
      console.error("D1Gateway error:", error);
      return Response.json({ error: "database error" }, { status: 500 });
    }
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
