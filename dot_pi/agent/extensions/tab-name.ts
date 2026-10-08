/**
 * tmux tab naming via an OpenRouter free-model router.
 *
 * - Auto-name: after the first completed agent turn, if the tmux window still
 *   has its default name, generate a short label from the pane scrollback and
 *   set it. Runs once per session; never overwrites a name you chose.
 * - /rename <name>   set the tmux window name explicitly.
 * - /rename          regenerate the name from the last 20 non-blank scrollback
 *                    lines of the current pane.
 *
 * Names the tmux WINDOW only (the pi session name is left to pi's own /name).
 * The naming call goes to OpenRouter with a list of free models; OpenRouter's
 * model routing falls through the list until one answers, so it stays free and
 * survives any single free model being down or rate-limited.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);

// Free models, tried in order by OpenRouter's router (falls through on error/429).
// Non-reasoning, instruction-following only: a model that emits chain-of-thought
// is useless here. ling verified terse; gemma solid when not rate-limited.
const FREE_MODELS = [
  "inclusionai/ling-3.0-flash-sante:free",
  "google/gemma-4-26b-a4b-it:free",
  "google/gemma-4-31b-it:free",
];

const SYSTEM_PROMPT =
  "You label terminal tabs. Reply with ONLY a 2-4 word label (max 24 chars) " +
  "for what this terminal is doing, based on the scrollback. Title case, spaces " +
  "and hyphens allowed. No quotes, no explanation, no trailing punctuation.";

/** First line, quotes stripped, odd chars to spaces, collapsed, capped at 24. */
function sanitize(raw: string): string {
  return raw
    .trim()
    .split("\n")[0]
    .replace(/["'`]/g, "")
    .replace(/[^\w .-]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 24)
    .trim();
}

/** Last `n` non-blank lines of a block of text. */
function lastNonBlank(text: string, n: number): string {
  const lines = text.split("\n").filter((l) => l.trim().length > 0);
  return lines.slice(-n).join("\n");
}

async function tmux(args: string[]): Promise<string> {
  const { stdout } = await run("tmux", args);
  return stdout;
}

/** window_name, pane_current_command, automatic-rename for the current pane. */
async function paneInfo(pane: string) {
  const out = await tmux([
    "display-message", "-p", "-t", pane,
    "#{window_name}\t#{pane_current_command}\t#{automatic-rename}",
  ]);
  const [windowName = "", command = "", autoRename = ""] = out.trim().split("\t");
  return { windowName, command, autoRename };
}

async function captureScrollback(pane: string): Promise<string> {
  const out = await tmux(["capture-pane", "-p", "-t", pane, "-S", "-200"]);
  return lastNonBlank(out, 20);
}

async function setWindowName(pane: string, name: string): Promise<void> {
  // Turn off tmux's own automatic-rename for this window, else it reverts.
  await tmux(["set-window-option", "-t", pane, "automatic-rename", "off"]);
  await tmux(["rename-window", "-t", pane, name]);
}

async function generateName(scrollback: string): Promise<string | null> {
  const key = process.env.OPENROUTER_API_KEY;
  if (!key || !scrollback.trim()) return null;
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 10_000);
  try {
    const res = await fetch("https://openrouter.ai/api/v1/chat/completions", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        models: FREE_MODELS,
        // Many free models are reasoning models that burn the whole token budget
        // thinking and return empty content; disable it so we get a bare label.
        reasoning: { enabled: false },
        messages: [
          { role: "system", content: SYSTEM_PROMPT },
          { role: "user", content: `Terminal scrollback:\n\n${scrollback}\n\nLabel:` },
        ],
        max_tokens: 24,
        temperature: 0.2,
      }),
      signal: ctl.signal,
    });
    if (!res.ok) return null;
    const json: any = await res.json();
    const content = (json?.choices?.[0]?.message?.content ?? "").trim();
    // A compliant label is one short line. Reject ramblers (e.g. a reasoning
    // model that slipped into the list and emitted chain-of-thought).
    if (content.length > 40) return null;
    const name = sanitize(content);
    return name.length >= 2 ? name : null;
  } finally {
    clearTimeout(timer);
  }
}

export default function (pi: ExtensionAPI) {
  const pane = process.env.TMUX_PANE;
  const inTmux = Boolean(process.env.TMUX && pane);
  let attempted = false;

  async function rename(ctx: any): Promise<void> {
    const scrollback = await captureScrollback(pane!);
    const name = await generateName(scrollback);
    if (!name) {
      ctx?.ui?.notify?.("Could not generate a tab name (no scrollback or API down?)", "warning");
      return;
    }
    await setWindowName(pane!, name);
    ctx?.ui?.notify?.(`Tab renamed: ${name}`, "info");
  }

  // Auto-name once, only if the window still has its default name.
  pi.on("agent_end", async (_ev: any, ctx: any) => {
    if (attempted || !inTmux) return;
    attempted = true;
    try {
      const { windowName, command, autoRename } = await paneInfo(pane!);
      // tmux prints automatic-rename as "1"/"0" (not "on"/"off").
      const isDefault = autoRename === "1" || autoRename === "on" || windowName === command;
      if (!isDefault) return; // user chose a name; leave it alone
      await rename(ctx);
    } catch {
      // Naming is a convenience; never disturb the session.
    }
  });

  pi.registerCommand("rename", {
    description: "Rename this tmux tab; with no argument, auto-generate from scrollback",
    handler: async (args: string, ctx: any) => {
      if (!inTmux) {
        ctx?.ui?.notify?.("Not inside tmux; nothing to rename", "warning");
        return;
      }
      attempted = true; // an explicit rename counts as the once-per-session attempt
      const explicit = args.trim();
      try {
        if (explicit) {
          await setWindowName(pane!, sanitize(explicit) || explicit.slice(0, 24));
          ctx?.ui?.notify?.(`Tab renamed: ${explicit}`, "info");
          return;
        }
        await rename(ctx);
      } catch (e: any) {
        ctx?.ui?.notify?.(`Rename failed: ${e?.message ?? e}`, "error");
      }
    },
  });
}
