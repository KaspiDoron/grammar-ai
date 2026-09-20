import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import {
  CorrectionContext,
  CorrectionError,
  CorrectionResult,
  makeNonce,
  parseReply,
  systemPrompt,
  userMessage,
  validate,
} from "./correction";

export interface Provider {
  readonly name: string;
  correct(text: string, context: CorrectionContext, signal: AbortSignal): Promise<CorrectionResult>;
  available(): Promise<{ ok: boolean; detail: string }>;
}

export interface OllamaConfig {
  host: string;
  model: string;
}

/** Free, local, private. The default first choice. */
export class OllamaProvider implements Provider {
  readonly name = "Ollama";
  constructor(private readonly config: OllamaConfig) {}

  async correct(text: string, context: CorrectionContext, signal: AbortSignal): Promise<CorrectionResult> {
    const nonce = makeNonce();
    let response: Response;
    try {
      response = await fetch(`${this.config.host}/api/chat`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        signal,
        body: JSON.stringify({
          model: this.config.model,
          stream: false,
          think: false,
          format: "json",
          options: { temperature: 0 },
          messages: [
            { role: "system", content: systemPrompt(context, nonce) },
            { role: "user", content: userMessage(text, nonce) },
          ],
        }),
      });
    } catch (err) {
      if (signal.aborted) throw new CorrectionError("cancelled", "Cancelled.");
      throw new CorrectionError(
        "notConfigured",
        "Ollama isn't running. Install it from ollama.com, then run `ollama serve`."
      );
    }
    if (response.status === 404) {
      throw new CorrectionError(
        "notConfigured",
        `Ollama doesn't have the model "${this.config.model}". Run: ollama pull ${this.config.model}`
      );
    }
    if (!response.ok) throw new CorrectionError("unavailable", `Ollama returned HTTP ${response.status}.`);
    const data = (await response.json()) as { message?: { content?: string } };
    const content = data.message?.content ?? "";
    if (!content.trim()) throw new CorrectionError("empty", "No correction was returned.");
    return validate(parseReply(content).corrected, text, context);
  }

  async available(): Promise<{ ok: boolean; detail: string }> {
    try {
      const response = await fetch(`${this.config.host}/api/tags`, {
        signal: AbortSignal.timeout(4000),
      });
      if (!response.ok) return { ok: false, detail: `Ollama HTTP ${response.status}` };
      const data = (await response.json()) as { models?: { name: string }[] };
      const models = (data.models ?? []).map((m) => m.name);
      if (models.length === 0) return { ok: false, detail: "Ollama has no models" };
      const has = models.some(
        (m) => m === this.config.model || m.startsWith(`${this.config.model}:`) || this.config.model.startsWith(`${m}:`)
      );
      return has
        ? { ok: true, detail: `${this.config.model}, local` }
        : { ok: false, detail: `pull ${this.config.model}` };
    } catch {
      return { ok: false, detail: "Ollama not running" };
    }
  }

  async listModels(): Promise<string[]> {
    try {
      const response = await fetch(`${this.config.host}/api/tags`, { signal: AbortSignal.timeout(4000) });
      if (!response.ok) return [];
      const data = (await response.json()) as { models?: { name: string }[] };
      return (data.models ?? []).map((m) => m.name);
    } catch {
      return [];
    }
  }
}

/** The Claude Code CLI (`claude -p`), locked down. Free with a Claude sign-in. */
export class ClaudeCodeProvider implements Provider {
  readonly name = "Claude Code";
  constructor(private readonly explicitPath: string) {}

  private locate(): string | null {
    if (this.explicitPath) return existsSync(this.explicitPath) ? this.explicitPath : null;
    const home = homedir();
    const candidates = [
      "/opt/homebrew/bin/claude",
      "/usr/local/bin/claude",
      `${home}/.local/bin/claude`,
      `${home}/.claude/local/claude`,
    ];
    return candidates.find((p) => existsSync(p)) ?? null;
  }

  async correct(text: string, context: CorrectionContext, signal: AbortSignal): Promise<CorrectionResult> {
    const executable = this.locate();
    if (!executable) {
      throw new CorrectionError("notConfigured", "Claude Code isn't installed. Get it from claude.com/claude-code.");
    }
    const nonce = makeNonce();
    const args = [
      "-p",
      "--model", "sonnet",
      "--output-format", "json",
      "--tools", "",
      "--strict-mcp-config",
      "--disable-slash-commands",
      "--no-session-persistence",
      "--setting-sources", "",
      "--effort", "low",
      "--system-prompt", systemPrompt(context, nonce),
    ];
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
      DISABLE_AUTOUPDATER: "1",
      DISABLE_TELEMETRY: "1",
      DISABLE_ERROR_REPORTING: "1",
    };
    delete env.CLAUDECODE;

    const stdout = await runProcess(executable, args, userMessage(text, nonce), env, 30000, signal);
    let envelope: { result?: string; is_error?: boolean; structured_output?: { corrected_text?: string } };
    try {
      envelope = JSON.parse(stdout.trim());
    } catch {
      throw new CorrectionError("unavailable", "Claude Code returned an unexpected response.");
    }
    if (envelope.is_error) throw new CorrectionError("unavailable", "Claude Code reported an error.");
    const result = envelope.structured_output?.corrected_text ?? envelope.result ?? "";
    if (!result.trim()) throw new CorrectionError("empty", "No correction was returned.");
    return validate(parseReply(result).corrected, text, context);
  }

  async available(): Promise<{ ok: boolean; detail: string }> {
    const executable = this.locate();
    if (!executable) return { ok: false, detail: "not installed" };
    try {
      const out = await runProcess(executable, ["--version"], "", process.env, 8000, new AbortController().signal);
      return { ok: true, detail: out.trim() || "installed" };
    } catch {
      return { ok: false, detail: "couldn't run claude" };
    }
  }
}

function runProcess(
  executable: string,
  args: string[],
  stdin: string,
  env: NodeJS.ProcessEnv,
  timeoutMs: number,
  signal: AbortSignal
): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { env });
    let out = "";
    let err = "";
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      reject(new CorrectionError("timeout", "The AI took too long to respond."));
    }, timeoutMs);
    const onAbort = () => {
      child.kill("SIGTERM");
      reject(new CorrectionError("cancelled", "Cancelled."));
    };
    signal.addEventListener("abort", onAbort, { once: true });

    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("error", (e) => {
      clearTimeout(timer);
      signal.removeEventListener("abort", onAbort);
      reject(new CorrectionError("unavailable", `Couldn't launch the AI: ${e.message}`));
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      signal.removeEventListener("abort", onAbort);
      if (code === 0 || out.trim()) resolve(out);
      else reject(new CorrectionError("unavailable", err.split("\n")[0]?.slice(0, 120) || `exit ${code}`));
    });
    child.stdin.on("error", () => {}); // a child that exits early must not crash us
    child.stdin.end(stdin);
  });
}

/**
 * Tries providers in order until one succeeds. A provider that fails with an
 * outage is skipped for a cooldown so the editor does not pay its timeout on
 * every keystroke; a bad-request or bad-reply error is surfaced at once and
 * never silently retried on another provider.
 */
export class FailoverProvider implements Provider {
  readonly name = "Automatic";
  private benchedUntil = new Map<string, number>();

  constructor(
    private readonly providers: Provider[],
    private readonly cooldownMs = 60000,
    private readonly now: () => number = Date.now
  ) {}

  async correct(text: string, context: CorrectionContext, signal: AbortSignal): Promise<CorrectionResult> {
    if (this.providers.length === 0) throw new CorrectionError("notConfigured", "No AI provider is configured.");
    const time = this.now();
    let firstOutage: CorrectionError | undefined;

    const attempt = async (provider: Provider): Promise<CorrectionResult | undefined> => {
      try {
        const result = await provider.correct(text, context, signal);
        this.benchedUntil.delete(provider.name);
        return result;
      } catch (err) {
        const error = err instanceof CorrectionError ? err : new CorrectionError("unavailable", String(err));
        if (error.kind === "cancelled") throw error;
        if (error.isOutage) {
          this.benchedUntil.set(provider.name, this.now() + this.cooldownMs);
          if (!firstOutage) firstOutage = error;
          return undefined;
        }
        throw error; // bad request / bad reply: do not retry elsewhere
      }
    };

    for (const provider of this.providers) {
      if (this.isHealthy(provider.name, time)) {
        const result = await attempt(provider);
        if (result) return result;
      }
    }
    for (const provider of this.providers) {
      if (!this.isHealthy(provider.name, time)) {
        const result = await attempt(provider);
        if (result) return result;
      }
    }
    throw firstOutage ?? new CorrectionError("unavailable", "No provider was available.");
  }

  async available(): Promise<{ ok: boolean; detail: string }> {
    for (const provider of this.providers) {
      const status = await provider.available();
      if (status.ok) {
        const backups = this.providers.length - 1;
        return { ok: true, detail: backups > 0 ? `${provider.name} (+${backups} backup)` : provider.name };
      }
    }
    return { ok: false, detail: "set up Ollama or Claude Code" };
  }

  private isHealthy(name: string, time: number): boolean {
    const until = this.benchedUntil.get(name);
    return until === undefined || time >= until;
  }
}
