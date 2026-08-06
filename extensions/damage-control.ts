// Damage-control safety hook for Pi 0.82.x.
//
// Ported from https://github.com/disler/pi-vs-claude-code
// (extensions/damage-control.ts). Modified by Okky Mabruri; deviations from
// upstream are marked `PORT:` and each has a reason -- see ../README.md.
//
// The full notice is kept inline because this file is installed standalone
// into ~/.pi/ -- a copy of it must carry its own attribution.
//
//   MIT License
//
//   Copyright (c) 2026 IndyDevDan
//   Copyright (c) 2026 Okky Mabruri
//
//   Permission is hereby granted, free of charge, to any person obtaining a
//   copy of this software and associated documentation files (the "Software"),
//   to deal in the Software without restriction, including without limitation
//   the rights to use, copy, modify, merge, publish, distribute, sublicense,
//   and/or sell copies of the Software, and to permit persons to whom the
//   Software is furnished to do so, subject to the following conditions:
//
//   The above copyright notice and this permission notice shall be included in
//   all copies or substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//   FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//   DEALINGS IN THE SOFTWARE.
//
// Purpose here: make this repo's credential-file rule code-enforced instead of
// discipline-enforced. AGENTS.md says "never read files containing
// credentials"; that rule was violated 4x in one session. This blocks it.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

// PORT: upstream parses YAML via the `yaml` npm package. Pi does not bundle it,
// so a missing dep would throw at load and leave the session UNPROTECTED with
// no signal. JSON needs no dep and cannot fail that way. A guard that silently
// doesn't load is worse than no guard.
const RULES_BASENAME = "damage-control-rules.json";

interface Rule {
	pattern: string;
	reason: string;
	ask?: boolean;
}

interface Rules {
	bashToolPatterns: Rule[];
	zeroAccessPaths: string[];
	readOnlyPaths: string[];
	noDeletePaths: string[];
	// PORT: upstream always calls ctx.abort() on a block, killing the whole run.
	// That makes any DELEGATED survey over a config directory impossible: the
	// first protected file ends the session and the caller gets nothing back
	// after minutes of work. Denying the access is the security requirement;
	// killing the turn is not. Default false = deny and let the agent continue
	// with actionable feedback (upstream ships this as a separate
	// "damage-control-continue" variant). Set true for interactive sessions
	// where stopping to tell the human is the desired behaviour.
	abortOnBlock: boolean;
}

const EMPTY: Rules = {
	bashToolPatterns: [], zeroAccessPaths: [], readOnlyPaths: [], noDeletePaths: [],
	abortOnBlock: false,
};

const ANTI_WORKAROUND_ABORT =
	"\n\nDO NOT attempt to work around this restriction. DO NOT retry with " +
	"alternative commands, paths, or approaches that achieve the same result. " +
	"Report this block to the user exactly as stated and ask how they would like to proceed.";

// When continuing, the agent still must not route around the denial -- but it
// SHOULD carry on with the rest of the task and report this path as blocked.
const ANTI_WORKAROUND_CONTINUE =
	"\n\nDO NOT retry this path, and DO NOT use an alternative command or tool " +
	"to reach the same content -- the denial is deliberate. DO continue with the " +
	"rest of the task, and report this specific path as blocked in your answer.";

// --- pure matchers -------------------------------------------------------
//
// These were nested inside the extension closure, where nothing could reach
// them. None of them touch `rules`, `pi` or `ctx`; they are lifted to module
// scope and exported so damage-control.test.ts can drive them directly. That
// test is the reason a rule that was both too broad AND too narrow (see
// bashReadOnlyViolation) survived unnoticed.

function expandTilde(p: string): string {
	return p.startsWith("~") ? path.join(os.homedir(), p.slice(1)) : p;
}

function resolvePath(p: string, cwd: string): string {
	return path.resolve(cwd, expandTilde(p));
}

// Substring search that only counts a hit when the next char is not a
// path-word char, so `~/Desktop/YT` does not match `~/Desktop/YT_archive`.
export function commandReferencesPath(command: string, protectedPath: string): boolean {
	if (!protectedPath) return false;
	let idx = command.indexOf(protectedPath);
	while (idx >= 0) {
		const after = command[idx + protectedPath.length];
		if (!after || !/[A-Za-z0-9_-]/.test(after)) return true;
		idx = command.indexOf(protectedPath, idx + 1);
	}
	return false;
}

export function isPathMatch(targetPath: string, pattern: string, cwd: string): boolean {
	const resolvedPattern = expandTilde(pattern);

	if (resolvedPattern.endsWith("/")) {
		const abs = path.isAbsolute(resolvedPattern) ? resolvedPattern : path.resolve(cwd, resolvedPattern);
		return targetPath.startsWith(abs);
	}

	const regexPattern = resolvedPattern.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*");
	const regex = new RegExp(`^${regexPattern}$|^${regexPattern}/|/${regexPattern}$|/${regexPattern}/`);
	const relativePath = path.relative(cwd, targetPath);

	return (
		regex.test(targetPath) ||
		regex.test(relativePath) ||
		targetPath.includes(resolvedPattern) ||
		relativePath.includes(resolvedPattern)
	);
}

/**
 * Does any whitespace-separated word in a bash command match a glob rule?
 *
 * isPathMatch above answers "is this resolved path forbidden" for the file
 * tools, which know their argument is a path. A bash command is a string:
 * the filename is one token among verbs, flags and pipes, so it has to be
 * split first and each token tested on its own.
 *
 * Only patterns containing `*` go through here; plain literals are already
 * covered by the substring check at the call site.
 */
export function commandMatchesGlob(command: string, pattern: string): boolean {
	if (!pattern.includes("*")) return false;

	const regexBody = expandTilde(pattern)
		.replace(/[.+^${}()|[\]\\]/g, "\\$&")
		.replace(/\*/g, "[^\\s]*");
	const regex = new RegExp(`^${regexBody}$`);

	// Strip shell punctuation that would otherwise ride along on the token
	// and defeat the anchors: quotes, redirects, pipes, separators.
	return command
		.split(/\s+/)
		.map((tok) => tok.replace(/^["'<>|;&()]+|["'<>|;&()]+$/g, ""))
		.some((tok) => tok.length > 0 && (regex.test(tok) || regex.test(path.basename(tok))));
}

// --- readOnlyPaths, bash side --------------------------------------------
//
// "Read-only" means reads are ALLOWED. Answering that needs two separate
// questions -- does the command name the path, and does it try to write --
// where the old rule asked one bad one. See bashReadOnlyViolation.

// Anything that can create, overwrite, truncate or relabel a file it names.
// Matched against a segment's COMMAND WORD only, never the whole command --
// see segmentWrites for why that distinction is the whole ballgame.
const WRITE_VERBS = new Set([
	"rm", "rmdir", "mv", "cp", "ln", "touch", "truncate", "shred", "tee", "dd",
	"chmod", "chown", "chgrp", "install", "mkdir", "unlink", "patch",
]);
const INPLACE_TOOLS = new Set(["sed", "gsed", "perl", "ruby"]);
// An in-place flag as an argv TOKEN: -i, -pi, -i.bak, --in-place. Not a regex
// over the command string, which matched ` -i ` inside a quoted sed script.
const INPLACE_FLAG = /^(--in-place|-[A-Za-z]*i)/;
// Env assignments and wrappers to skip when looking for the command word, so
// `FOO=1 sudo rm x` still reads as `rm`.
const NOT_THE_VERB = /^([A-Za-z_][A-Za-z0-9_]*=|(sudo|command|env|nohup|time|exec)$)/;

/**
 * Split a command into pipeline segments: `|`, `||`, `&&`, `;`, newline.
 *
 * `>|` is normalised to `>` first, or the noclobber-override redirect would
 * split a segment in half.
 */
function segments(command: string): string[] {
	return command.replace(/>\|/g, ">").split(/\|\||&&|[|;\n]/);
}

// Blank out quoted spans before looking for flags: in `sed -nE '/ -i /p' f`
// the ` -i ` is part of the sed script, not an option, and a naive whitespace
// split hands it back as its own token.
function stripQuoted(s: string): string {
	return s.replace(/'[^']*'|"[^"]*"/g, " ");
}

function tokens(segment: string): string[] {
	return stripQuoted(segment).trim().split(/\s+/).filter((t) => t.length > 0);
}

/**
 * Does this ONE pipeline segment run a writing command?
 *
 * The verb must be the segment's command word. Testing the whole command
 * string instead -- which is what shipped first -- blocks `git log --patch`
 * (matches `patch`), `grep -n install ~/.claude/settings.json` (matches
 * `install`, grep's search term) and `grep -R sed -i /etc/`. All three are
 * ordinary read-only work, and all three were denied.
 */
function segmentWrites(segment: string): boolean {
	const toks = tokens(segment);
	let i = 0;
	while (i < toks.length && NOT_THE_VERB.test(toks[i])) i++;
	if (i >= toks.length) return false;

	const verb = path.basename(toks[i].replace(/^["']+|["']+$/g, ""));
	if (WRITE_VERBS.has(verb)) return true;
	// sed/perl/ruby only write with an in-place flag, and only their OWN flags
	// count: `sed -nE '/ -i /p' f` is a read.
	return INPLACE_TOOLS.has(verb) && toks.slice(i + 1).some((t) => INPLACE_FLAG.test(t));
}

function tokenMatchesReadOnly(tok: string, rop: string): boolean {
	const exp = expandTilde(rop);
	if (rop.includes("*")) return commandMatchesGlob(tok, rop);
	if (rop.endsWith("/")) return tok.startsWith(rop) || tok.startsWith(exp) || tok.includes("/" + rop);
	return tok === rop || tok === exp || tok.endsWith("/" + rop);
}

// Does the command redirect output INTO this path? Testing the whole command
// for `>` is what the old rule effectively did, and it matched every
// pipeline. Only the token after a redirect operator is a write target.
export function redirectsToPath(command: string, rop: string): boolean {
	// `[|&]?` covers the noclobber override `>|` and the both-streams form
	// `>&file`; without it the char class rejected the target and both slipped.
	const re = /\d*>>?[|&]?\s*([^\s;&|)>]+)/g;
	let m: RegExpExecArray | null;
	while ((m = re.exec(command)) !== null) {
		// `2>&1` captures `1`, which matches nothing. Harmless.
		if (tokenMatchesReadOnly(m[1].replace(/^["']+|["']+$/g, ""), rop)) return true;
	}
	return false;
}

export function commandReferencesReadOnly(command: string, rop: string): boolean {
	const exp = expandTilde(rop);
	if (rop.includes("*")) return commandMatchesGlob(command, rop);
	// Trailing-slash patterns are directory prefixes, and commandReferencesPath
	// requires the following character NOT to be a path-word char -- which is
	// exactly what follows a directory separator. `/etc/` against
	// `cat /etc/hosts` fails it. So prefixes use plain substring, and only leaf
	// paths get the word-boundary treatment that keeps `~/Desktop/YT` off
	// `~/Desktop/YT_archive`. Do not collapse these two branches.
	if (rop.endsWith("/")) return command.includes(rop) || command.includes(exp);
	return commandReferencesPath(command, rop) || (exp !== rop && commandReferencesPath(command, exp));
}

/**
 * Which readOnlyPath, if any, does this bash command look like it will WRITE?
 * Returns the matching rule, or null.
 *
 * The old inline version was:
 *
 *   command.includes(rop) && (/[\s>|]/.test(command) || /\b(rm|mv|sed)\b/.test(command))
 *
 * `/[\s>|]/` is true of any command containing ONE SPACE, so the write-intent
 * arm never rejected anything and the rule collapsed to `command.includes(rop)`.
 * Every readOnlyPath entry behaved as zero-access for bash: `ls .git/refs`,
 * `cat .git/HEAD`, `cat /etc/hosts` and `wc -l package-lock.json` were all
 * denied as "may modify". (`git status`/`log`/`diff` contain no literal
 * `.git/` and were never affected.)
 *
 * It was simultaneously too NARROW: substring-only, so `*.lock` could never
 * fire -- no command contains a literal `*` -- and no tilde expansion, so
 * `~/.zshrc` matched only when spelled that way. zeroAccessPaths got both
 * fixes; this branch never did.
 *
 * Not a loosening of the file tools: readOnlyPaths is consulted for them only
 * in the write/edit branch. read/grep/find/ls answer to zeroAccessPaths alone,
 * so `read ~/.zshrc` already succeeded and the bash over-block protected
 * nothing an agent could not reach another way.
 *
 * The verb and the path must be in the SAME pipeline segment. Without that,
 * `cat package-lock.json | tee /tmp/copy` blocks: the path is read in segment
 * one and the write lands in segment two, on a different file entirely.
 *
 * This errs toward permitting, which is the correct direction for a hook that
 * is not a sandbox. Known and deliberate misses: `git config --local` writes
 * .git/config without naming it; so do `npm install` (package-lock.json),
 * `uv sync` (uv.lock) and git porcelain generally. Anything routed through a
 * variable, a command substitution or a subprocess is outside the hook by
 * construction. rm/mv are still gated by noDeletePaths, and write/edit are
 * gated separately -- do not grow a bash parser here.
 *
 * So this catches LITERAL DIRECT WRITES only. It is a guard against the model
 * making a mistake, not against anyone determined.
 */
export function bashReadOnlyViolation(command: string, readOnlyPaths: string[]): string | null {
	const segs = segments(command);
	for (const rop of readOnlyPaths) {
		// Redirects are scanned across the whole command: the operator and its
		// target are always adjacent, so segmenting buys nothing here.
		if (redirectsToPath(command, rop)) return rop;
		for (const seg of segs) {
			if (commandReferencesReadOnly(seg, rop) && segmentWrites(seg)) return rop;
		}
	}
	return null;
}

function ruleCount(r: Rules): number {
	return r.bashToolPatterns.length + r.zeroAccessPaths.length + r.readOnlyPaths.length + r.noDeletePaths.length;
}

export default function (pi: ExtensionAPI) {
	let rules: Rules = EMPTY;
	// PORT: fail closed. Upstream continues with empty rules when loading fails,
	// which silently disables protection. Here a parse failure blocks every tool
	// call until it's fixed.
	let loadError: string | null = null;
	// Fail-closed used to be SILENT to the caller. Announce it once per run --
	// see the comment on the tool_call branch that reads this.
	let loadErrorAnnounced = false;

	// PORT: guard on ctx.mode, NOT ctx.hasUI.
	//
	// rpc.md is explicit: `ctx.hasUI` is TRUE in RPC mode, because dialog
	// methods are "functional via the extension UI sub-protocol" -- i.e.
	// ctx.ui.confirm() emits an extension_ui_request on stdout and BLOCKS
	// until the client writes a matching extension_ui_response to stdin.
	// A benchmark harness that doesn't implement that sub-protocol hangs
	// forever. Only "tui" mode has a real human able to answer.
	const canPrompt = (ctx: any) => ctx.mode === "tui";

	// notify/setStatus are fire-and-forget in RPC (emitted, no response
	// expected), so they are safe -- but stderr is more useful for a harness.
	function say(ctx: any, msg: string) {
		if (canPrompt(ctx)) ctx.ui.notify(msg);
		else process.stderr.write(`[damage-control] ${msg}\n`);
	}

	pi.on("session_start", async (_event, ctx) => {
		loadErrorAnnounced = false;
		const candidates = [
			path.join(ctx.cwd, ".pi", RULES_BASENAME),
			path.join(ctx.cwd, "code-assistant", "pi", RULES_BASENAME),
			path.join(os.homedir(), ".pi", RULES_BASENAME),
		];
		const rulesPath = candidates.find((p) => fs.existsSync(p)) ?? null;

		if (!rulesPath) {
			loadError = `no ${RULES_BASENAME} found (looked in: ${candidates.join(", ")})`;
			say(ctx, `🛡️ Damage-Control: ${loadError} -- BLOCKING ALL TOOL CALLS`);
			return;
		}

		try {
			const loaded = JSON.parse(fs.readFileSync(rulesPath, "utf8")) as Partial<Rules>;
			rules = {
				bashToolPatterns: loaded.bashToolPatterns ?? [],
				zeroAccessPaths: loaded.zeroAccessPaths ?? [],
				readOnlyPaths: loaded.readOnlyPaths ?? [],
				noDeletePaths: loaded.noDeletePaths ?? [],
				// PI_DC_ABORT=1 forces abort regardless of the rules file. Set by
				// pi-delegate.sh for research runs: a credential-path block during
				// a web survey is anomalous and reads as prompt injection, so the
				// turn should stop rather than be told "continue with the rest".
				abortOnBlock: process.env.PI_DC_ABORT === "1" ? true : (loaded.abortOnBlock ?? false),
			};
			// Compile every regex now so a bad pattern fails at startup, not
			// mid-run on the one command it was meant to catch.
			for (const r of rules.bashToolPatterns) new RegExp(r.pattern);
			loadError = null;
			say(ctx, `🛡️ Damage-Control: ${ruleCount(rules)} rules from ${rulesPath}`);
			if (canPrompt(ctx)) ctx.ui.setStatus(`🛡️ Damage-Control: ${ruleCount(rules)} rules`);
		} catch (err) {
			rules = EMPTY;
			loadError = `failed to parse ${rulesPath}: ${err instanceof Error ? err.message : String(err)}`;
			say(ctx, `🛡️ Damage-Control: ${loadError} -- BLOCKING ALL TOOL CALLS`);
		}
	});

	pi.on("tool_call", async (event, ctx) => {
		if (loadError) {
			// This branch used to write NOTHING. The session_start handler does say
			// something, but its text is "BLOCKING ALL TOOL CALLS" -- which does not
			// contain the literal `Blocked` that pi-delegate.sh greps for. So a run
			// with a missing or corrupt rules file denied every tool call, exited 0,
			// and returned an empty answer with no GUARD: line: indistinguishable
			// from the model finding nothing. Announce once, with wording the grep
			// matches. Once, not per call: a refused agent retries, and one line per
			// retry buries the reason it is being refused.
			if (!loadErrorAnnounced) {
				loadErrorAnnounced = true;
				say(ctx, `🛑 Blocked ${event.toolName} and every later tool call: rules did not load (${loadError})`);
			}
			return { block: true, reason: `🛑 BLOCKED: damage-control rules did not load (${loadError}). Fix the rules file before running tools.${ANTI_WORKAROUND_ABORT}` };
		}

		let violationReason: string | null = null;
		let shouldAsk = false;

		const inputPaths: string[] = [];
		if (isToolCallEventType("read", event) || isToolCallEventType("write", event) || isToolCallEventType("edit", event)) {
			inputPaths.push(event.input.path);
		} else if (isToolCallEventType("grep", event) || isToolCallEventType("find", event) || isToolCallEventType("ls", event)) {
			inputPaths.push(event.input.path || ".");
		}

		if (isToolCallEventType("grep", event) && event.input.glob) {
			for (const zap of rules.zeroAccessPaths) {
				if (event.input.glob.includes(zap) || isPathMatch(event.input.glob, zap, ctx.cwd)) {
					violationReason = `Glob matches zero-access path: ${zap}`;
					break;
				}
			}
		}

		if (!violationReason) {
			outer: for (const p of inputPaths) {
				const resolved = resolvePath(p, ctx.cwd);
				for (const zap of rules.zeroAccessPaths) {
					if (isPathMatch(resolved, zap, ctx.cwd)) {
						violationReason = `Access to zero-access path restricted: ${zap}`;
						break outer;
					}
				}
			}
		}

		// PORT: inspect network tools. Upstream predates them and dispatches only
		// on read/write/edit/grep/find/ls/bash, so anything else fell through to
		// `block: false`. Registering pi-web-access added three uninspected tools
		// (`web_search`, `fetch_content`, `get_search_content`) that reach the
		// network — the one channel by which data can LEAVE the machine.
		//
		// zeroAccessPaths guarantees a credential never reaches the model. It says
		// nothing about egress. A URL is attacker-controllable and can carry
		// content in its query string, so the whole input is stringified and
		// checked rather than trusting a `url` field to be the only vector.
		if (!violationReason) {
			const NETWORK_TOOLS = ["web_search", "fetch_content", "get_search_content"];
			if (NETWORK_TOOLS.includes(event.toolName)) {
				const blob = JSON.stringify(event.input ?? {});

				for (const zap of rules.zeroAccessPaths) {
					const bare = zap.replace(/^[~*]+/, "").replace(/\*/g, "");
					if (bare.length > 3 && blob.includes(bare)) {
						violationReason = `Network tool ${event.toolName} references zero-access path: ${zap}`;
						break;
					}
				}
				// SSRF / local-file exfil targets. A delegated web survey has no
				// legitimate reason to fetch the loopback interface, the cloud
				// metadata endpoint, or a file:// URL.
				if (!violationReason) {
					const SSRF = /\b(file:\/\/|localhost|127\.0\.0\.1|0\.0\.0\.0|169\.254\.169\.254|\[::1\]|metadata\.google\.internal)/i;
					const m = blob.match(SSRF);
					if (m) violationReason = `Network tool ${event.toolName} targets a local/metadata address: ${m[1]}`;
				}
			}
		}

		if (!violationReason) {
			if (isToolCallEventType("bash", event)) {
				const command = event.input.command;

				for (const rule of rules.bashToolPatterns) {
					if (new RegExp(rule.pattern).test(command)) {
						violationReason = rule.reason;
						shouldAsk = !!rule.ask;
						break;
					}
				}

				// Substring match alone leaves every wildcard rule dead here: six of
				// the zeroAccessPaths entries are globs (*.env, *.pem, *.key,
				// *serviceAccount*.json, *.tfstate, *credentials*), and no command
				// literally contains the character `*`. `cat prod-credentials.json`
				// and `cat terraform.tfstate` both passed. The path branch above
				// already globs via isPathMatch; bash did not.
				//
				// Keep includes() as well as the glob test rather than replacing it:
				// literal entries like `.env` catch `app.env` as a substring, which
				// the anchored glob would not. Union, so current behaviour is a
				// subset of new behaviour and nothing that blocked before stops.
				if (!violationReason) {
					for (const zap of rules.zeroAccessPaths) {
						if (command.includes(zap) || commandMatchesGlob(command, zap)) {
							violationReason = `Bash command references zero-access path: ${zap}`;
							break;
						}
					}
				}

				// A read is not a write, and this rule used to deny both. The whole
				// story, and what the old one-liner actually evaluated to, is on
				// bashReadOnlyViolation at module scope.
				if (!violationReason) {
					const rop = bashReadOnlyViolation(command, rules.readOnlyPaths);
					if (rop) {
						violationReason =
							`Bash command may modify read-only path: ${rop} -- reading it is allowed; ` +
							`re-issue without the writing command if reading was the intent`;
					}
				}

				if (!violationReason && (/\brm\b/.test(command) || /\bmv\b/.test(command))) {
					for (const ndp of rules.noDeletePaths) {
						const expanded = expandTilde(ndp);
						if (commandReferencesPath(command, ndp) || (expanded !== ndp && commandReferencesPath(command, expanded))) {
							violationReason = `Bash command attempts to delete/move protected path: ${ndp}`;
							break;
						}
					}
				}
			} else if (isToolCallEventType("write", event) || isToolCallEventType("edit", event)) {
				outer2: for (const p of inputPaths) {
					const resolved = resolvePath(p, ctx.cwd);
					for (const rop of rules.readOnlyPaths) {
						if (isPathMatch(resolved, rop, ctx.cwd)) {
							violationReason = `Modification of read-only path restricted: ${rop}`;
							break outer2;
						}
					}
				}
			}
		}

		if (!violationReason) return { block: false };

		const detail = isToolCallEventType("bash", event) ? event.input.command : JSON.stringify(event.input);

		// PORT: `ask` rules fail CLOSED when there is no UI to ask. Upstream
		// would await ctx.ui.confirm() in headless and hang or throw.
		if (shouldAsk && canPrompt(ctx)) {
			const confirmed = await ctx.ui.confirm(
				"🛡️ Damage-Control Confirmation",
				`Dangerous command detected: ${violationReason}\n\nCommand: ${detail}\n\nDo you want to proceed?`,
				{ timeout: 30000 },
			);
			if (confirmed) {
				pi.appendEntry("damage-control-log", { tool: event.toolName, input: event.input, rule: violationReason, action: "confirmed_by_user" });
				return { block: false };
			}
			ctx.ui.setStatus(`⚠️ Blocked: ${violationReason.slice(0, 30)}...`);
			pi.appendEntry("damage-control-log", { tool: event.toolName, input: event.input, rule: violationReason, action: "blocked_by_user" });
			if (rules.abortOnBlock) ctx.abort();
			return { block: true, reason: `🛑 BLOCKED by Damage-Control: ${violationReason} (User denied)${rules.abortOnBlock ? ANTI_WORKAROUND_ABORT : ANTI_WORKAROUND_CONTINUE}` };
		}

		const headlessNote = shouldAsk ? " (ask-rule, non-interactive mode -- failing closed)" : "";
		say(ctx, `🛑 Blocked ${event.toolName}: ${violationReason}${headlessNote}`);
		if (canPrompt(ctx)) ctx.ui.setStatus(`⚠️ Blocked: ${violationReason.slice(0, 30)}...`);
		pi.appendEntry("damage-control-log", { tool: event.toolName, input: event.input, rule: violationReason, action: "blocked" });
		if (rules.abortOnBlock) ctx.abort();
		return { block: true, reason: `🛑 BLOCKED by Damage-Control: ${violationReason}${headlessNote}${rules.abortOnBlock ? ANTI_WORKAROUND_ABORT : ANTI_WORKAROUND_CONTINUE}` };
	});
}
