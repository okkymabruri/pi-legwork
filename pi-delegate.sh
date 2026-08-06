#!/usr/bin/env bash
# Delegate one task to Pi, return a POINTER not a payload.
#
# The saving comes entirely from what does NOT re-enter the caller's context,
# so this script is built around keeping output small. Whether that is worth it
# depends on your task and models: benchmark/ measures both arms, and no result
# file ships, so measure before trusting any ratio.
#
#   - Pi writes its full work to a file.
#   - stdout is a short head + the file path.
#   - Claude reads the file only if it actually needs the detail.
#
# Usage:
#   pi-delegate.sh "task text"
#   pi-delegate.sh -m minimax/MiniMax-M3 -o /tmp/out.md "task text"
#   pi-delegate.sh -p research "search the web for X, cite sources"
#   pi-delegate.sh -2 "independent read on this decision: <the whole problem>"
#   pi-delegate.sh -f task.md
#   pi-delegate.sh -T high "task"      # reasoning effort (see PI_DELEGATE_THINKING)
#   pi-delegate.sh -nc "task"          # don't load the cwd's AGENTS.md/CLAUDE.md
#   pi-delegate.sh -S "task"           # load skills (opt-in; see PI_DELEGATE_SKILLS_DIR)
#   pi-delegate.sh -s audit-1 "task"   # named resumable session (default: none)
#   pi-delegate.sh --models            # what models pi actually has configured
#   pi-delegate.sh --doctor            # check the install, say what is missing
#
# Env:
#   PI_DELEGATE_MODEL   default model, e.g. zai/glm-5.2 (see README: Providers)
#   PI_DELEGATE_SO_MODEL  stronger model for -2 (second opinion)
#   PI_DELEGATE_HEAD    lines of output echoed to stdout (default: 40)
#   PI_DELEGATE_SKILLS_DIR  where -S looks for <name>/SKILL.md (default: ~/.pi/agent/skills)
#   PI_DELEGATE_TIMEOUT seconds before the run is killed (default: 600 local,
#                       1800 research/full -- see the TIMEOUT note below)
#   PI_DELEGATE_THINKING  reasoning effort passed to pi: off|minimal|low|medium|
#                       high|xhigh|max. UNSET by default, and deliberately so --
#                       see the note above THINK_ARG before you turn it on.

set -uo pipefail

# Deliberately NOT `${PI_DELEGATE_MODEL:?...}`. That aborts on line 30, before
# any flag is parsed -- so `--doctor`, `--models` and `-h`, the three things that
# tell a new user what is wrong, would all die with the error they exist to
# explain. The requirement is enforced after parsing instead.
DEFAULT_MODEL="${PI_DELEGATE_MODEL:-}"
HEAD_LINES="${PI_DELEGATE_HEAD:-40}"
TIMEOUT="${PI_DELEGATE_TIMEOUT:-}"   # profile-dependent default, resolved after parsing
PROFILE="${PI_DELEGATE_PROFILE:-local}"
THINKING="${PI_DELEGATE_THINKING:-}"
MODEL=""            # empty until -m; lets -2 pick without overriding an explicit choice
OUTFILE=""
TASK=""

# Second opinion runs on a stronger tier than everything else, and that is a
# deliberate exception to the economics the rest of this script is built on.
#
# Every other shape is delegated to SAVE tokens, so the cheap fill-first chain
# is exactly right: volume is the whole point. Second opinion is delegated for
# INDEPENDENCE -- Pi's lack of conversation context, normally the weakness, is
# the entire reason to ask. It is one call returning a short answer, so the
# stronger tier costs almost nothing, while a weak model's confident agreement
# is worse than not asking at all.
SECOND_OPINION=0
SO_MODEL="${PI_DELEGATE_SO_MODEL:-$DEFAULT_MODEL}"

# Project context files (AGENTS.md / CLAUDE.md in the cwd) load by DEFAULT.
#
# The docs asserted the opposite -- "Pi sees only the prompt, no CLAUDE.md" --
# for as long as this wrapper has existed. Measured 2026-07-28: a canary in
# AGENTS.md came back verbatim, and so did one in CLAUDE.md with no AGENTS.md
# present. Which of the two wins when both exist is untested. Only the cwd is
# read: a run from a dir with neither returned NONE, and the global
# ~/.claude/CLAUDE.md never appeared.
#
# Left ON for surveys -- repo conventions are usually what you'd have had to
# put in the prompt anyway. Forced OFF for -2 below, and available as -nc.
NO_CONTEXT=0
# Skills are OPT-IN. See SKILLS_ARG below for why they are not on by default.
WANT_SKILLS=0
SKILLS_DIR="${PI_DELEGATE_SKILLS_DIR:-$HOME/.pi/agent/skills}"

# Sessions are OFF by default, which is what the one-shot semantics already
# implied -- but pi was saving one per cwd regardless, and ~/.pi/agent/sessions
# had reached 30 MB across ~21 project dirs with nothing ever reaping it.
#
# -s <id> opts back in, for the one shape that wants it: a follow-up on a
# survey that would otherwise re-pay the per-call floor and re-send the whole
# context. --session-id (not -c) because it is deterministic and creates on
# first use -- "continue the previous session" is ambiguous the moment six
# workers run in parallel.
SESSION_ID=""

# Tool profiles -- the blast-radius lever.
#
# Registering web tools put a network-egress channel in the same agent that
# holds bash/read/edit. Two consequences that only appear together:
#   - anything Pi legitimately read can leave via a URL query string;
#   - fetched web content is UNTRUSTED INPUT, so a page can instruct the agent
#     to read a path or run a command.
#
# Splitting the tool set by job removes the combination rather than trying to
# police it: a local survey has no network to exfiltrate through, and a
# research run has no bash/edit for an injected page to aim at. The token floor
# follows the same lever, since every registered tool's schema ships per call.
#
#   readonly  read/grep/find/ls -- no bash, no network. Cannot mutate.
#   local     + bash. CAN write; read-only here is intent, not enforcement.
#   research  network only, NO bash/edit/write     ~4.7k floor
#   full      everything -- both halves at once; opt in deliberately
profile_tools() {
  case "$1" in
    # No bash, so no subprocess and nothing that mutates the tree. This is the
    # only profile where "read-only" is ENFORCED rather than merely intended.
    #
    # It exists because the claim was wrong for a while: `local` was documented
    # as read-only, but it carries bash, and a delegate asked to overwrite a
    # file did exactly that. Task selection is not a boundary.
    readonly) echo "read,grep,find,ls" ;;
    local)    echo "read,grep,find,ls,bash" ;;
    # `mcp` is a single PROXY tool -- the adapter's design ("one proxy tool
    # (~200 tokens) instead of hundreds"). Enumerating individual MCP tool
    # names does NOT work; they are reachable through the proxy, not
    # registered.
    #
    # SECURITY: allowlisting `mcp` grants every ENABLED server, so the
    # fail-closed boundary lives in ~/.pi/agent/mcp.json `disabled` flags, not
    # here. Importing host configs once pulled in `node_repl_js` -- a
    # JavaScript REPL, i.e. arbitrary code execution -- into the very profile
    # that removes bash. Keep that file an explicit allowlist and keep
    # hostConfigDiscovery off.
    research) echo "web_search,fetch_content,get_search_content,read,mcp" ;;
    # ENUMERATED, not empty. An empty string means no --tools flag, which means
    # the child inherits every registered tool -- including anything installed
    # later. `pi install npm:pi-subagents` would silently add subagent,
    # subagent_wait, custom-agent, intercom and contact_supervisor to this
    # profile, giving a delegate the power to spawn its own delegates on a
    # boundary nobody reviewed. PHILOSOPHY.md excludes nested subagents on
    # purpose; that exclusion has to be enforced somewhere, and this is where.
    #
    # Listing the tools means a genuinely new built-in has to be added here by
    # hand. That is the intended trade: `full` loses a tool quietly rather than
    # gaining an unreviewed one quietly.
    full)     echo "read,grep,find,ls,bash,edit,write,web_search,source_check,fetch_content,get_search_content,mcp,parallel" ;;
    *) echo "unknown profile: $1 (want readonly|local|research|full)" >&2; exit 1 ;;
  esac
}

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# `pi --list-models` already prints provider, model, context, max output,
# thinking and image support. Pass it through rather than maintaining a second
# catalogue that would drift from whatever pi is actually configured with.
list_models() {
  command -v pi >/dev/null || { echo "pi is not on PATH -- see README: Install" >&2; exit 1; }
  pi --list-models ${1:+"$1"}
  exit 0
}

# Every check answers "what do I do next", because the failure this replaces was
# a bare `PI_DELEGATE_MODEL: set PI_DELEGATE_MODEL...` abort that told a new user
# nothing about which models existed or where to configure one.
#
# Order matters: each check is a precondition for the one below it, so the first
# failure is the one worth fixing and later checks would only add noise.
doctor() {
  rc=0
  say() { printf '%-4s %s\n' "$1" "$2"; }

  if command -v pi >/dev/null; then
    say "ok" "pi on PATH ($(command -v pi))"
  else
    say "FAIL" "pi not on PATH -- install it: https://github.com/badlogic/pi-mono"
    echo; echo "Nothing else can be checked until pi is installed."
    exit 1
  fi

  models="$(pi --list-models 2>/dev/null)"
  count=$(printf '%s\n' "$models" | tail -n +2 | grep -c . || true)
  if [ "${count:-0}" -gt 0 ] 2>/dev/null; then
    say "ok" "$count model(s) configured in pi"
  else
    say "FAIL" "no models configured -- see docs/PROVIDERS.md, then re-run --doctor"
    rc=1
  fi

  if [ -n "$DEFAULT_MODEL" ]; then
    if printf '%s\n' "$models" | grep -q -- "$DEFAULT_MODEL"; then
      say "ok" "PI_DELEGATE_MODEL=$DEFAULT_MODEL is configured"
    else
      say "FAIL" "PI_DELEGATE_MODEL=$DEFAULT_MODEL is not in pi --list-models"
      rc=1
    fi
  else
    say "FAIL" "PI_DELEGATE_MODEL is unset -- pick one from 'pi-delegate --models'"
    rc=1
  fi

  if [ -n "${PI_DELEGATE_SO_MODEL:-}" ]; then
    say "ok" "second opinion uses $PI_DELEGATE_SO_MODEL"
  else
    say "note" "PI_DELEGATE_SO_MODEL unset -- -2 will reuse PI_DELEGATE_MODEL."
    say "" "     A stronger model here is worth it: weak agreement is worse than none."
  fi

  # The guard is optional, so a missing one is a note, not a failure -- but the
  # note has to say plainly what is not being protected.
  if [ -f "$HOME/.pi/damage-control-rules.json" ]; then
    say "ok" "guard rules at ~/.pi/damage-control-rules.json"
  else
    say "note" "no guard rules -- credential paths are NOT blocked. See README: Install"
  fi

  echo
  [ "$rc" = 0 ] && echo "Ready." || echo "Fix the FAIL lines above, then re-run --doctor."
  exit "$rc"
}

case "${1:-}" in
  --models) shift; list_models "${1:-}" ;;
  --doctor) doctor ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    -m|--model)   MODEL="$2"; shift 2 ;;
    -p|--profile) PROFILE="$2"; shift 2 ;;
    -o|--out)     OUTFILE="$2"; shift 2 ;;
    -f|--file)    TASK="$(cat "$2")"; shift 2 ;;
    -s|--session) SESSION_ID="$2"; shift 2 ;;
    -T|--thinking) THINKING="$2"; shift 2 ;;
    -nc|--no-context) NO_CONTEXT=1; shift ;;
    -S|--skills)  WANT_SKILLS=1; shift ;;
    -2|--second-opinion) SECOND_OPINION=1; shift ;;
    -h|--help)    usage 0 ;;
    --)           shift; TASK="$*"; break ;;
    -*)           echo "unknown flag: $1" >&2; usage 1 ;;
    *)            TASK="$*"; break ;;
  esac
done

# Enforced here rather than at assignment, so --doctor/--models/-h still run
# when nothing is configured yet. Points at the tool that explains the problem
# instead of restating it.
if [ -z "$DEFAULT_MODEL" ] && [ -z "$MODEL" ]; then
  echo "no delegate model set." >&2
  echo "  export PI_DELEGATE_MODEL=<provider/model>   # 'pi-delegate --models' lists them" >&2
  echo "  pi-delegate --doctor                        # checks the whole install" >&2
  exit 1
fi

# Resolved after parsing so flag order does not matter, and so an explicit -m
# always wins over the -2 default.
if [ -z "$MODEL" ]; then
  [ "$SECOND_OPINION" = 1 ] && MODEL="$SO_MODEL" || MODEL="$DEFAULT_MODEL"
fi

# Second opinion never loads project context, and this is not a preference.
# The whole reason to ask Pi is that it has none of this conversation; a repo
# CLAUDE.md is exactly HALF the context, which is the worst of the three
# states -- confident answer to the wrong question, which the rules doc already
# names as worse than not asking. Full context is impossible, so take none.
[ "$SECOND_OPINION" = 1 ] && NO_CONTEXT=1

# The stronger tier is reserved for second opinion, and reserving it means
# refusing it elsewhere rather than trusting everyone to remember. Research is
# the shape most likely to drift: it is the other one where quality feels
# worth paying for, but it is many fetches, so volume is the point and the
# cheap chain is correct. Left as a convention this would erode within a week.
#
# Only enforceable when the two are actually different models. If
# PI_DELEGATE_SO_MODEL is unset it falls back to PI_DELEGATE_MODEL, and then
# every call would match this test and be refused.
if [ "$SO_MODEL" != "$DEFAULT_MODEL" ] && [ "$MODEL" = "$SO_MODEL" ] && [ "$SECOND_OPINION" != 1 ]; then
  echo "refusing -m $SO_MODEL without -2: that model is reserved for second" >&2
  echo "opinion, where one short answer justifies the stronger tier. Every" >&2
  echo "other shape -- research included -- runs on $DEFAULT_MODEL. Use -2 if" >&2
  echo "this really is a second opinion." >&2
  exit 1
fi

# The timeout is a property of the PROFILE, and 600 was measured on the wrong
# one. Local greps finish in 25-60s; research runs its fetches serially and was
# measured at 298s and 582s -- so the same 600s ceiling that is 10x headroom for
# a grep is a 3% margin for a survey. Two research runs died at exactly 605s
# with rc=143 and 0B, having already spent 2.5M and 3.2M tokens; one was killed
# mid-sentence while writing its final answer. Killing at the deadline is the
# worst outcome available: full cost paid, nothing returned.
if [ -z "$TIMEOUT" ]; then
  case "$PROFILE" in research|full) TIMEOUT=1800 ;; *) TIMEOUT=600 ;; esac
fi

[ -n "$TASK" ] || { echo "no task given" >&2; usage 1; }
command -v pi >/dev/null || { echo "pi not on PATH" >&2; exit 1; }

if [ -z "$OUTFILE" ]; then
  mkdir -p "${TMPDIR:-/tmp}/pi-delegate"
  OUTFILE="${TMPDIR:-/tmp}/pi-delegate/$(date +%Y%m%d-%H%M%S)-$$.md"
fi
mkdir -p "$(dirname "$OUTFILE")"

# Terseness is the economics, not a style preference. A correct-but-verbose
# delegate erases the saving: on the same task GLM returned ~60 chars and
# MiniMax 1,498, for identical answers.
CONTRACT="You are a delegated worker. Another agent will read your answer, so it
pays tokens for every word you EMIT -- but nothing for what you work out along
the way. Think as carefully as the task deserves; be brief only in the output.

Rules:
- Answer only what is asked. No preamble, no restatement of the task, no
  summary of your process, no offer to do more.
- Take the time to be right. Checking your own answer costs the caller nothing
  and is cheaper than a wrong answer they act on. What you must not do is
  narrate the checking.
- Every factual claim carries a locator, so it can be verified without redoing
  your work: file path and line number, a commit SHA, a source URL, or a page
  number. A claim you cannot locate is one you should not make -- say what you
  could not establish instead.
- If the answer is a list, emit the list. If it is one word, emit one word.

TASK:
$TASK"

# The generic contract optimises for terseness. Second opinion needs one more
# thing: permission to disagree. A delegate told only to be brief drifts toward
# agreeing briefly, which is the one outcome that makes the call worthless.
[ "$SECOND_OPINION" = 1 ] && CONTRACT="You are giving an INDEPENDENT second opinion. You have no
access to the asker's conversation, and that is the point -- do not try to
infer what they want to hear. Judgement is in scope here, unlike a survey.
- Lead with the verdict: agree, disagree, or the load-bearing assumption.
- If you disagree, say so first and plainly. Confident agreement that turns
  out to be wrong is worse than no answer.
- If the problem as stated is missing something you would need, name that gap
  instead of guessing around it.
- Be brief. Reasoning only where it changes the verdict.

PROBLEM:
$TASK"

START=$(date +%s)

# --mode json, not -p.
#
# `pi -p` prints only the answer text, so the ONLY model name available to
# report was the one we requested -- and with the default model that is a fill-first
# chain, not a model. The skill's rule 1 ("check responseModel, scale
# verification to the serving tier") was therefore unfollowable, and the
# quota-drain indicator was dead: a run could be served by GPT-5.6 Sol or
# MiniMax M3 with no way to tell.
#
# --mode json emits the same answer plus `responseModel` -- the model that
# actually served -- and per-message token usage. Output stays thin because
# we extract rather than echo the stream.
#
# PI_OFFLINE skips startup version/catalog network calls (documented as
# startup-only; it does not disable web tools). Set PI_DELEGATE_ONLINE=1 to
# turn it off if a research delegation ever behaves as though it is blocked.
RAWFILE="$OUTFILE.jsonl"
PI_OFFLINE="${PI_DELEGATE_ONLINE:+0}"; PI_OFFLINE="${PI_OFFLINE:-1}"

TOOLS_ARG=()
PROFILE_TOOLS="$(profile_tools "$PROFILE")"
[ -n "$PROFILE_TOOLS" ] && TOOLS_ARG=(--tools "$PROFILE_TOOLS")

# Sessions off unless -s asked for one; see SESSION_ID above for why.
SESSION_ARG=(--no-session)
[ -n "$SESSION_ID" ] && SESSION_ARG=(--session-id "$SESSION_ID")

CONTEXT_ARG=()
[ "$NO_CONTEXT" = 1 ] && CONTEXT_ARG=(--no-context-files)

# Skills: OFF unless -S asks for them, and that default is the economics.
#
# Every skill announced puts its name and description in the system prompt of
# EVERY request in the run. The whole argument for delegating is that a request
# costs roughly what it costs regardless of what it accomplished, so widening
# the resident floor on all delegations to serve the few that need a skill is
# backwards. Ask for them on the calls that need them:
#
#   pi-delegate -S -p readonly "using the prospera-slides skill, ..."
#
# WHY NOT `pi --skill`, WHICH EXISTS AND LOOKS RIGHT:
#
# It does not reach the model on this route. Measured with a canary skill whose
# description carried a nonsense token, asked with -nt so the agent had no tools
# to go find the file with:
#
#   pi -p -nt "what is the canary token?"                      -> NONE
#   pi -p -nt --skill .../zz-canary/SKILL.md "same question"   -> NONE
#
# ~/.pi/agent/skills is not auto-discovered either: loadSkills() runs with
# includeDefaults:false. And the obvious probe LIES — without -nt the agent
# answers with the token every time, because `read`/`find` let it go and open
# the file. Any check of this that leaves tools enabled proves nothing.
#
# So the block is assembled here and passed with --append-system-prompt, which
# is verifiable and does what --skill was supposed to. Same contract pi's own
# skills feature uses: names and descriptions resident, body read on demand.
#
# Second opinion never loads them, for the same reason it never loads project
# context: -2 is bought for independence, and a skill is a house opinion.
SKILLS_ARG=()
SKILLS_COUNT=0
SKILLS_FILE=""
if [ "$WANT_SKILLS" = 1 ] && [ "$SECOND_OPINION" != 1 ] && [ -d "$SKILLS_DIR" ]; then
  SKILLS_FILE="$(mktemp -t pi-delegate-skills)"
  {
    echo
    echo "The following skills provide specialized instructions for specific tasks."
    echo "Use the read tool to load a skill's file when the task matches its description."
    echo "Resolve any relative path inside a skill against that skill's own directory."
    echo
    echo "<available_skills>"
  } >"$SKILLS_FILE"
  for _sk in "$SKILLS_DIR"/*/SKILL.md; do
    [ -e "$_sk" ] || continue
    # name/description out of the YAML front matter; fall back to the directory.
    _nm="$(awk -F': *' '/^name: /{print $2; exit}' "$_sk")"
    _ds="$(awk -F': *' '/^description: /{sub(/^description: */,""); print; exit}' "$_sk")"
    [ -n "$_nm" ] || _nm="$(basename "$(dirname "$_sk")")"
    {
      echo "  <skill>"
      echo "    <name>${_nm}</name>"
      echo "    <description>${_ds}</description>"
      echo "    <location>${_sk}</location>"
      echo "  </skill>"
    } >>"$SKILLS_FILE"
    SKILLS_COUNT=$((SKILLS_COUNT + 1))
  done
  echo "</available_skills>" >>"$SKILLS_FILE"
  if [ "$SKILLS_COUNT" -gt 0 ]; then
    SKILLS_ARG=(--append-system-prompt "$SKILLS_FILE")
  else
    rm -f "$SKILLS_FILE"; SKILLS_FILE=""
    echo "pi-delegate: -S asked for skills but none found under $SKILLS_DIR" >&2
  fi
fi

# Reasoning effort is a PASS-THROUGH, unset by default, and that default is a
# measurement rather than caution.
#
# `pi --models` reports thinking: yes for the omniroute aliases, but on this
# route the flag is inert: the same prompt at --thinking off and --thinking high
# returned reasoning=0, output=7, and identical text both times. Either the
# openai-completions proxy does not forward a reasoning-effort parameter, or it
# does not report the tokens back. Defaulting it on would have looked like a
# quality improvement while changing nothing.
#
# It is still worth exposing, because it is a property of the ROUTE and not of
# this script -- a direct provider, or a different alias, may honour it. Turn it
# on only after checking that reasoning tokens actually move on your route.
THINK_ARG=()
[ -n "$THINKING" ] && THINK_ARG=(--thinking "$THINKING")

# A guard trip during a RESEARCH run is anomalous -- nothing legitimate reads a
# credential file while surveying the web, so it is a likely prompt-injection
# signal and the turn should stop rather than be told "continue with the rest".
[ "$PROFILE" = "research" ] && export PI_DC_ABORT=1

# `${arr[@]+"${arr[@]}"}`, not `"${arr[@]}"`. Under `set -u`, macOS bash 3.2
# treats an EMPTY array expansion as an unbound variable and aborts. That is
# not hypothetical: `-p full` sets TOOLS_ARG=() by design, so the full profile
# has never been able to run. Adding CONTEXT_ARG=() made it fire on every call
# that did not pass -nc.
PI_OFFLINE="$PI_OFFLINE" pi --mode json -p "$CONTRACT" --model "$MODEL" \
  ${TOOLS_ARG[@]+"${TOOLS_ARG[@]}"} \
  ${SESSION_ARG[@]+"${SESSION_ARG[@]}"} \
  ${CONTEXT_ARG[@]+"${CONTEXT_ARG[@]}"} \
  ${SKILLS_ARG[@]+"${SKILLS_ARG[@]}"} \
  ${THINK_ARG[@]+"${THINK_ARG[@]}"} \
  >"$RAWFILE" 2>"$OUTFILE.err" &
PI_PID=$!

# The skills block is a temp file only because --append-system-prompt reads
# one; nothing downstream needs it once pi has started.
[ -n "$SKILLS_FILE" ] && rm -f "$SKILLS_FILE"

# Self-terminating watchdog: polls in 1s steps and exits as soon as pi is gone.
#
# Do NOT use `( sleep "$TIMEOUT"; kill ... ) &` here. `kill $WATCHDOG` kills the
# subshell but NOT its child `sleep`, which then lingers as an orphan for the
# full timeout -- every delegation would leak one stray process. Short sleeps
# mean the worst case is a 1s orphan, and the loop reaps itself normally.
#
# The flag file is how a watchdog kill is told apart from any other SIGTERM --
# a user interrupt and the parent harness reaping a backgrounded shell both
# arrive as rc=143 too, and the header used to report all three as an
# unexplained `STDERR: [damage-control] ...` line that named the wrong thing.
rm -f "$OUTFILE.timeout"
( while [ "$TIMEOUT" -gt 0 ] 2>/dev/null; do
    kill -0 "$PI_PID" 2>/dev/null || exit 0
    sleep 1
    TIMEOUT=$((TIMEOUT - 1))
  done
  : >"$OUTFILE.timeout"
  kill "$PI_PID" 2>/dev/null ) &
WATCHDOG=$!

wait "$PI_PID"; RC=$?
# `disown` looks like the obvious fix for the "Terminated: 15" notice but must
# not be used here -- job control is off in a non-interactive shell and it made
# `wait` hang outright.
{ kill "$WATCHDOG" && wait "$WATCHDOG"; } 2>/dev/null
END=$(date +%s)

# Surface guard blocks explicitly -- a blocked run is the safety hook working,
# not the model failing, and the caller must be able to tell them apart.
#
# NOT `grep -c ... || echo 0`: grep prints its count AND exits 1 when the count
# is zero, so the fallback fires too and the variable becomes "0\n0".
# `Blocked\|BLOCKING`: the second catches the session_start message for a
# missing or corrupt rules file, which names the paths it looked in. Matching
# only `Blocked` let a run where the guard refused EVERY tool call print no
# GUARD: line at all.
GUARD=$(grep -c 'damage-control.*\(Blocked\|BLOCKING\)' "$OUTFILE.err" 2>/dev/null) || true
GUARD=${GUARD:-0}

# Extract the answer text from the JSONL stream into OUTFILE, so callers and
# the head-preview below behave exactly as they did under `pi -p`.
if [ -s "$RAWFILE" ]; then
  # Every extraction goes through `fromjson? // empty`, which parses each line
  # independently and drops the ones that fail.
  #
  # Plain `jq -r 'select(...)' file` looks equivalent and is not: jq ABORTS on
  # the first unparseable line, so one malformed line anywhere in a 2 MB stream
  # empties the whole answer. That is exactly what happened -- pi splits very
  # long message_update lines, jq hit `Invalid numeric literal`, and four
  # delegations returned 0 bytes while still reporting rc=0. A silent empty
  # result is the worst failure mode this wrapper has: it looks like the model
  # found nothing.
  jqline() { jq -R -r "fromjson? // empty | $1" "$RAWFILE" 2>/dev/null; }

  jqline 'select(.type=="message_end" and .message.role=="assistant")
          | [.message.content[]? | select(.type=="text") | .text] | join("")' \
    | sed '/^$/d' >"$OUTFILE" || : >"$OUTFILE"

  # Salvage, fallback only: a killed run never emits the final `message_end`,
  # so the extraction above returns 0B even when the model had already written
  # most of its answer. The run that prompted this had 941 chars of a finished
  # four-point list with sources, cut mid-sentence, and all of it was thrown
  # away. `message_update` carries the CUMULATIVE partial for the message in
  # flight, so keeping the longest partial per message reconstructs the stream.
  #
  # Guarded on an empty OUTFILE so a run that ended normally is byte-identical.
  PARTIAL=0
  if [ ! -s "$OUTFILE" ]; then
    jqline 'if .type=="message_start" then "S\t"
            elif (.type=="message_update" or .type=="message_end")
                 and .message.role=="assistant"
              then "T\t" + ([.message.content[]? | select(.type=="text") | .text]
                            | join("") | gsub("\n"; "\u0001"))
            else empty end' \
    | awk '{ tag=substr($0,1,1); val=substr($0,3)
             if (tag=="S") { n++; best[n]="" }
             else if (length(val) > length(best[n])) best[n]=val }
           END { for (i=1; i<=n; i++) if (length(best[i])) print best[i] }' \
    | tr '\001' '\n' >"$OUTFILE.partial"
    if [ -s "$OUTFILE.partial" ]; then
      PARTIAL=1
      { echo "[PARTIAL -- the run was killed before it finished. This is the text"
        echo " that had already streamed; the answer is cut off, not complete.]"
        echo
        cat "$OUTFILE.partial"; } >"$OUTFILE"
    fi
    rm -f "$OUTFILE.partial"
  fi

  # The model that ACTUALLY served, not the one requested. With the default model these
  # differ by design -- that difference is the quota-drain indicator.
  SERVED=$(jqline 'select(.type=="message_end" and .message.role=="assistant")
                   | .message.responseModel // .message.model' \
           | grep -v '^null$' | sort -u | paste -sd, -)
  # Sum input+output per request, NOT usage.totalTokens.
  #
  # `.input` is the whole conversation re-sent each turn, so it climbs
  # monotonically (measured: 4,834 -> 100,850 across one 12-message run) --
  # summing it is correct for BILLING, since every request pays its full input.
  # `totalTokens` is not: it disagrees with input+output on some messages
  # (88,299 + 116 reported as 149,343) because it folds in cache and reasoning
  # counters, so summing it inflated the figure ~1.5x. The old number was
  # 1,218,368 where real consumption was ~798k.
  #
  # `ctx:` is the last request's input+output -- the high-water context, which
  # is the number that matters for a model's window.
  TOKENS=$(jqline 'select(.type=="message_end" and .message.role=="assistant")
                   | .message.usage | [(.input // 0), (.output // 0)] | @tsv' \
           | awk '{s+=$1+$2} END{print s+0}')
  CTX=$(jqline 'select(.type=="message_end" and .message.role=="assistant")
                | .message.usage | [(.input // 0), (.output // 0)] | @tsv' \
        | awk 'END{print $1+$2+0}')
  TOOLS=$(jqline 'select(.type=="tool_execution_end") | .toolName' \
          | sort | uniq -c | awk '{printf "%s×%s ", $1, $2}')
  # Report dropped lines rather than hiding them -- a large count means the
  # answer above may be partial.
  TOTAL_LINES=$(wc -l <"$RAWFILE" | tr -d ' ')
  GOOD_LINES=$(jq -R 'fromjson? // empty | 1' "$RAWFILE" 2>/dev/null | wc -l | tr -d ' ')
  DROPPED=$((TOTAL_LINES - GOOD_LINES))
else
  : >"$OUTFILE"; SERVED=""; TOKENS=0; CTX=0; TOOLS=""; DROPPED=0; PARTIAL=0
fi

TIMED_OUT=0
[ -f "$OUTFILE.timeout" ] && TIMED_OUT=1
rm -f "$OUTFILE.timeout"

BYTES=$(wc -c <"$OUTFILE" | tr -d ' ')
LINES=$(wc -l <"$OUTFILE" | tr -d ' ')

echo "--- pi-delegate ---"
echo "profile:   $PROFILE  (tools: ${PROFILE_TOOLS:-<all>})"
echo "requested: $MODEL"
echo "served by: ${SERVED:-<unknown>}   tokens: ${TOKENS:-?} (ctx ${CTX:-?})"
echo "session:   ${SESSION_ID:-<none>}   context files: $([ "$NO_CONTEXT" = 1 ] && echo "off" || echo "cwd AGENTS.md/CLAUDE.md")   skills: $([ "$SKILLS_COUNT" -gt 0 ] && echo "$SKILLS_COUNT" || echo "off")"
[ -n "$TOOLS" ] && echo "tools:     $TOOLS"
echo "elapsed:   $((END - START))s   rc=$RC   output: ${BYTES}B / ${LINES} lines"
[ "${DROPPED:-0}" -gt 0 ] 2>/dev/null && \
  echo "stream:    $DROPPED unparseable line(s) skipped -- answer may be partial"
[ "$TIMED_OUT" = 1 ] && \
  echo "TIMEOUT: killed at ${TIMEOUT}s by the watchdog, mid-run. Raise it with"
[ "$TIMED_OUT" = 1 ] && \
  echo "         PI_DELEGATE_TIMEOUT=<seconds>. The tokens were already spent."
[ "${PARTIAL:-0}" = 1 ] && \
  echo "PARTIAL: no final message -- recovered what had streamed. Answer is cut off."
[ "$BYTES" = "0" ] && [ "$RC" = "0" ] && \
  echo "EMPTY:   rc=0 but no answer text. Check $RAWFILE -- this is a harness"
[ "$BYTES" = "0" ] && [ "$RC" = "0" ] && \
  echo "         problem, NOT the model reporting that it found nothing."
echo "file:      $OUTFILE"
[ "$GUARD" != "0" ] && {
  echo "GUARD:   $GUARD block(s) -- safety hook denied access:"
  grep 'damage-control.*\(Blocked\|BLOCKING\)' "$OUTFILE.err" | sed 's/^/         /'
}
[ "$RC" != "0" ] && echo "STDERR:  $(tail -3 "$OUTFILE.err" | tr '\n' ' ')"
echo "---"

if [ "$LINES" -le "$HEAD_LINES" ]; then
  cat "$OUTFILE"
else
  head -n "$HEAD_LINES" "$OUTFILE"
  echo
  echo "[truncated: $((LINES - HEAD_LINES)) more lines -- read $OUTFILE if needed]"
fi

exit "$RC"
