// Table test for the bash-side readOnlyPaths matcher.
//
// Why this file exists: the rule it covers shipped both too broad AND too
// narrow at the same time -- it denied `ls .git/refs` as "may modify" while
// `*.lock` could never fire at all -- and nothing caught either half, because
// four distinct matching algorithms lived in this extension with zero tests.
//
// No test-runner dependency, for the same reason the rules file is JSON and not
// YAML (see the PORT note in damage-control.ts): a check that cannot fail to
// load is worth more than a check with features.
//
//   node --experimental-strip-types extensions/damage-control.test.ts
//
// Rules come from the shipped damage-control-rules.json, so the table tracks
// the real policy rather than a copy that drifts.

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, "..");

// The extension imports the pi SDK, which is installed globally by pi's own
// installer and is not resolvable from this directory. Link it in on first run
// (node_modules/ is gitignored) rather than making the test skip itself.
const scope = path.join(REPO, "node_modules", "@earendil-works");
if (!fs.existsSync(path.join(scope, "pi-coding-agent"))) {
	const globalRoot = execFileSync("npm", ["root", "-g"], { encoding: "utf8" }).trim();
	const src = path.join(globalRoot, "@earendil-works", "pi-coding-agent");
	if (!fs.existsSync(src)) {
		console.error(`cannot find the pi SDK at ${src} -- is pi installed?`);
		process.exit(2);
	}
	fs.mkdirSync(scope, { recursive: true });
	fs.symlinkSync(src, path.join(scope, "pi-coding-agent"), "dir");
	console.log(`linked ${src} -> node_modules/@earendil-works/pi-coding-agent`);
}

const { bashReadOnlyViolation, commandMatchesGlob, commandReferencesReadOnly, redirectsToPath } = await import(
	"./damage-control.ts"
);

const rules = JSON.parse(fs.readFileSync(path.join(REPO, "damage-control-rules.json"), "utf8"));
const ROP: string[] = rules.readOnlyPaths;
const SETTINGS_ABS = path.join(os.homedir(), ".claude", "settings.json");

// [command, expected rule that blocks it, or null for "must be allowed"]
const CASES: [string, string | null][] = [
	// --- the reported false positive, and its whole family ------------------
	["ls .git/refs/heads", null],
	["cat .git/HEAD", null],
	["grep -rn origin .git/config", null],
	["ls -la .git/", null],
	["ls .git/refs 2>&1", null], // `2>&1` must not read as a redirect target
	["git status --porcelain", null], // never contained `.git/` to begin with
	["cat /etc/hosts", null],
	["wc -l package-lock.json", null],
	["grep -c name uv.lock", null],
	["cat foo.lock", null],
	["diff .git/config /tmp/expected", null],
	[`cat ${SETTINGS_ABS}`, null],

	// --- still blocked: real writes ----------------------------------------
	["rm -rf .git/", ".git/"],
	["sed -i '' s/a/b/ .git/config", ".git/"],
	["perl -pi -e s/a/b/ .git/config", ".git/"],
	["cp /tmp/x .git/config", ".git/"],
	["chmod 644 /etc/hosts", "/etc/"],
	["tee -a package-lock.json", "package-lock.json"],
	["truncate -s 0 uv.lock", "*.lock"],
	["rm foo.lock", "*.lock"],

	// --- redirects: only the TARGET token counts ---------------------------
	["echo x > uv.lock", "*.lock"],
	["echo x >> uv.lock", "*.lock"],
	["cat uv.lock > /tmp/copy", null], // reading FROM it, writing elsewhere
	["echo x >> ~/.claude/settings.json", "~/.claude/settings.json"],
	[`echo x >> ${SETTINGS_ABS}`, "~/.claude/settings.json"], // tilde-expanded form

	// --- sed without -i is a read ------------------------------------------
	["sed -n 5p uv.lock", null],
	["sed -e s/a/i/ .git/config", null],
];

let failed = 0;
for (const [command, expected] of CASES) {
	const got = bashReadOnlyViolation(command, ROP);
	if (got !== expected) {
		failed++;
		console.error(`FAIL  ${JSON.stringify(command)}\n      expected ${expected ?? "allow"}, got ${got ?? "allow"}`);
	}
}

// The two helpers whose absence was the "too narrow" half of the bug.
const UNIT: [boolean, boolean, string][] = [
	[commandMatchesGlob("wc -l uv.lock", "*.lock"), true, "glob matches a bare token"],
	[commandMatchesGlob("wc -l uv.lock", "uv.lock"), false, "glob helper ignores non-glob patterns"],
	[commandReferencesReadOnly("cat /etc/hosts", "/etc/"), true, "prefix rule matches a file under it"],
	[commandReferencesReadOnly("cat /etcetera", "/etc/"), false, "prefix rule needs the separator"],
	[redirectsToPath("echo x > uv.lock", "*.lock"), true, "redirect target matches a glob rule"],
	[redirectsToPath("cat uv.lock | wc -l", "*.lock"), false, "a pipe is not a redirect"],
];
for (const [got, expected, label] of UNIT) {
	if (got !== expected) {
		failed++;
		console.error(`FAIL  ${label}: expected ${expected}, got ${got}`);
	}
}

const total = CASES.length + UNIT.length;
console.log(failed ? `${failed}/${total} FAILED` : `${total} cases pass`);
process.exit(failed ? 1 : 0);
