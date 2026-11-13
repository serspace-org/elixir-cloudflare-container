import { DurableObject } from "cloudflare:workers";

const PORT = 4000;
const INACTIVITY_TIMEOUT_MS = 10 * 60 * 1000; // 10 minutes (allows WebSocket keepalive)

export interface Env {
  ELIXIR_CONTAINER: DurableObjectNamespace;
  SECRET_KEY_BASE: string;
  DATABASE_URL: string;
  PHX_HOST: string;
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
    return {
      PHX_SERVER: "true",
      SECRET_KEY_BASE: this.env.SECRET_KEY_BASE,
      DATABASE_URL: this.env.DATABASE_URL,
      PHX_HOST: this.env.PHX_HOST,
      PORT: String(PORT),
    };
  }

  private async startAndWait(): Promise<void> {
    const container = this.ctx.container!;
    if (!container.running) {
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
