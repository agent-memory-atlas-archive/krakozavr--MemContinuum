#!/usr/bin/env bash
# SessionStart hook. Behavior branches on the payload's `source` field
# in-script (SessionStart supports a matcher on `source` at the settings
# level too, but docs/DESIGN.md requires in-script gating as the
# defense of record):
#
#   startup | resume | clear
#                     -- initialize this session's state (start_code_sha /
#                        start_store_sha captured from the code/store roots'
#                        current git HEAD, via setdefault so a *resume* never
#                        resets a startup's original values), then prune
#                        state files older than 24h across this project.
#                        Silent UNLESS the standing-decisions digest (next
#                        paragraph) has something new to inject.
#
#   TOP-0132 L1/L2 (every source): after the per-source work above, always
#                        attempts the standing-decisions digest --
#                        `memidx.py standing --json`'s citation-only
#                        projection of every topic's own `standing:`
#                        pointer list, computed AFTER every state mutation
#                        the branch already makes (init/prune/rotate on
#                        startup; pending consumption on compact) so a
#                        watchdog kill during the digest's own subprocess
#                        calls loses only the digest, never that
#                        bookkeeping. A non-current index (missing,
#                        uninitialized, upgrade-required, stale, OR
#                        quarantined -- `standing` refuses on every one of
#                        these, unlike every other reader here) or an empty
#                        standing set injects nothing, logged
#                        `standing=skipped-<state>` / `standing=empty`.
#                        Otherwise: `startup`/`resume` dedupe by comparing
#                        the digest's hash against `state["standing_hash"]`
#                        inside the SAME locked state-update transform that
#                        sets it (never a separate read-then-write -- see
#                        mc_compute_standing's callers), logging
#                        `standing=dedup` on a match; `clear` and `compact`
#                        ALWAYS inject regardless of any stored hash (the
#                        context is gone either way), logging
#                        `standing=injected links=N bytes=B hash=H`. On
#                        `compact`, the digest is appended AFTER coverage's
#                        (or, failing that, look-back's) own text in the
#                        same additionalContext -- coverage stays first
#                        when it has evidence. Loaded is not applied -- this
#                        raises the odds a standing ruling is honored, it
#                        is not a guarantee.
#
#                        `clear` (INC-0108) is a fresh session, not a
#                        continuation: /clear commonly fires on the SAME
#                        session_id an earlier startup already created state
#                        for (a /clear mid-process, same CLI run), so unlike
#                        resume it must DISCARD most of whatever state is
#                        already on disk for this session_id before the
#                        setdefault init below runs -- a leftover turn-count/
#                        pending/look-back baseline from before the clear
#                        would misfire the coverage/look-back nudges against
#                        turns the cleared context no longer has, and a stale
#                        SessionEnd `ended_at` stamp has no business
#                        surviving into a session that is still running. ONE
#                        field survives the discard: `ledger` (the edited-
#                        but-not-yet-mapped-to-a-decision file list) is
#                        carried over as-is -- userprompt-remind.sh's
#                        coverage check (`memidx.py unmapped`) classifies
#                        candidates *only* from `state["ledger"]`, never from
#                        a tree walk, so wiping it would make any file edited
#                        before the clear that is still genuinely unmapped
#                        invisible to the coverage nudge for the rest of the
#                        session, unless it happens to be touched again post-
#                        clear -- silent evidence loss of exactly the kind
#                        this project treats as zero-tolerance. The
#                        discard-plus-carry-ledger happens inside the same
#                        locked mc_update_state_json transform (state
#                        rebuilt to just {"ledger": ...} at the top, only for
#                        clear) so there is no separate unlocked delete step
#                        and no window where a concurrent read sees a half-
#                        reset file.
#   compact           -- read state.pending (written by precompact-persist.sh
#                         right before compaction), and if it holds anything,
#                         inject it ONCE via hookSpecificOutput.additionalContext
#                         (SessionStart's additionalContext is the first thing
#                         the model sees post-compaction). Consumes (clears)
#                         pending afterward so a later resume-after-compact
#                         doesn't re-inject the same evidence. If coverage has
#                         no evidence AND pending's snapshotted
#                         (user_turn_count - last_growth_turn) >= 3, injects
#                         the look-back compact twin instead (WRITE-HOOKS-
#                         CONSENSUS.md addendum 2026-08-30) -- coverage always
#                         wins when it has evidence; the twin ignores the
#                         cooldown entirely (one-shot loss point), and stamps
#                         last_inject_turn/last_inject_ts on firing so the
#                         very next per-turn hook call doesn't immediately
#                         re-fire on the same stretch.
#   anything else      -- no-op, silent, logged only.
#
# Wording: "Coverage signal" / "Look-back signal" fact line + exactly one
# closing question, never an imperative, never "unrecorded", never a
# suggested topic name -- and NEVER a coverage-gap count when the underlying
# index was stale (never a false gap, docs/DESIGN.md ruling F).
#
# Env: see hooks/memlib.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# Watchdog guard (macOS port, docs/DESIGN.md SS8 port note, 2026-08-30;
# deduped into hooks/mc-watchdog.sh, finding 1, 2026-08-31): must be the
# literal first thing after resolving SCRIPT_DIR and sourcing
# mc-watchdog.sh (see its own header for what
# running it costs), strictly BEFORE sourcing memlib.sh (which
# does its own mkdir -p work) -- see
# hooks/userprompt-remind.sh's test_outer_deadline_covers_memlib_sourcing
# for why this ordering matters. A tiny python launcher
# (mc-watchdog.sh's MC_WATCHDOG_LAUNCHER_PY) starts this same script as a
# child in its own process group and kills the WHOLE group on a
# wall-clock budget (2s here; see hooks/mc-watchdog.sh), so an orphaned
# grandchild (e.g. a hung python call several layers deep, or the
# launcher itself being killed -- finding 1's SIGTERM/SIGINT/atexit fix)
# cannot outlive the deadline. Every python call this script and
# memlib.sh's helpers make therefore needs no timeout of its own -- this
# one watchdog bounds the entire run. Always exits 0; stdin/stdout/stderr
# are the real, inherited file descriptors (never piped through python),
# so passthrough is unbuffered. If MEMCONTINUUM_PYTHON (or the venv
# fallback) does not resolve to an executable, or mc-watchdog.sh failed
# to source (MC_WATCHDOG_LAUNCHER_PY unset), this falls through
# UNGUARDED instead of exec-ing a dead path -- memlib.sh's own "no python
# resolved" detection then fires exactly as it would with no guard at
# all.
# shellcheck source=mc-watchdog.sh
source "${MC_WATCHDOG_LIB_PATH:-$SCRIPT_DIR/mc-watchdog.sh}" 2>/dev/null
if [ -z "${MC_UNDER_TIMEOUT:-}" ]; then
    export MC_UNDER_TIMEOUT=1
    # MC_GUARD_PY is set by mc-watchdog.sh above (F6 fix, round 4: env ->
    # config.sh -> engine venv, same order memlib.sh uses for MC_PY).
    if [ -x "${MC_GUARD_PY:-}" ] && [ -n "${MC_WATCHDOG_LAUNCHER_PY:-}" ]; then
        "$MC_GUARD_PY" -c "$MC_WATCHDOG_LAUNCHER_PY" "${BASH:-bash}" "${BASH_SOURCE[0]}" "$@"
        exit 0
    fi
fi

# shellcheck source=memlib.sh
source "$SCRIPT_DIR/memlib.sh"

finish() {
    local extra="${2:-}"
    if [ -n "$extra" ]; then
        mc_log "sessionstart outcome=$1 $extra session=${SESSION_ID:-} source=${SOURCE:-}"
    else
        mc_log "sessionstart outcome=$1 session=${SESSION_ID:-} source=${SOURCE:-}"
    fi
    exit 0
}

PAYLOAD="$(cat)"
[ -z "$PAYLOAD" ] && finish "empty-payload"

eval "$(mc_extract_fields "$PAYLOAD" session_id source)" 2>/dev/null
[ -z "${SESSION_ID:-}" ] && finish "no-session-id"

STATE_FILE="$(mc_state_file_for "$MC_PROJECT" "$SESSION_ID")"

# mc_compute_standing -- TOP-0132 L1/L2. Runs `memidx.py standing --json`
# (never touches session state itself; callers below decide dedupe/
# persistence) and sets these globals:
#   STANDING_STATUS  "ready" | "empty" | "skipped-<state>"
#   STANDING_TEXT    the exact plain-text digest to inject (only set when
#                     STANDING_STATUS=ready -- header + one line per
#                     pointer, byte-identical to what --json's own hash/
#                     bytes describe, since both come from the SAME
#                     `memidx.py standing` query against an unchanged,
#                     current index)
#   STANDING_HASH / STANDING_LINKS / STANDING_BYTES  from --json, verbatim
#                     -- never recomputed here, so this hook can never
#                     disagree with `memidx.py standing --json` about what
#                     the digest's own hash or size is.
# Two `memidx.py standing` calls when there IS something to inject (one
# --json, for the structured hash/links/bytes memidx.py itself computes;
# one plain, for the exact text to inject) -- never more, and never a
# second call at all when the index refuses or the set is empty. Bash 3.2:
# no associative arrays, no `local -n`; globals by convention (this file is
# a leaf script, never sourced elsewhere).
STANDING_STATUS=""
STANDING_TEXT=""
STANDING_HASH=""
STANDING_LINKS=0
STANDING_BYTES=0

mc_compute_standing() {
    STANDING_STATUS="skipped-unavailable"
    STANDING_TEXT=""
    STANDING_HASH=""
    STANDING_LINKS=0
    STANDING_BYTES=0

    local args
    args=(standing --project "$MC_PROJECT" --db "$MC_DB_PATH")
    [ -n "${MEMCONTINUUM_ROOT:-}" ] && args+=(--root "$MEMCONTINUUM_ROOT")

    local json_out
    json_out="$(env PYTHONPATH= "$MC_PY" "$MC_MEMIDX" "${args[@]}" --json 2>>"$MC_LOG")"

    local meta_tmp
    meta_tmp="$(mktemp 2>/dev/null)" || return
    env PYTHONPATH= "$MC_PY" -c '
import json, sys

try:
    obj = json.loads(sys.argv[1] or "{}")
except Exception:
    obj = {}
if "hash" in obj:
    print("ok - %d %s %d" % (obj.get("links", 0), obj.get("hash", "-"), obj.get("bytes", 0)))
else:
    print("refused %s 0 - 0" % obj.get("state", "unknown"))
' "$json_out" >"$meta_tmp" 2>>"$MC_LOG"

    local kind rstate links hash nbytes
    read -r kind rstate links hash nbytes <"$meta_tmp" 2>/dev/null
    rm -f "$meta_tmp" 2>/dev/null

    if [ "${kind:-}" != "ok" ]; then
        STANDING_STATUS="skipped-${rstate:-unknown}"
        return
    fi
    if [ "${links:-0}" = "0" ]; then
        STANDING_STATUS="empty"
        return
    fi

    STANDING_TEXT="$(env PYTHONPATH= "$MC_PY" "$MC_MEMIDX" "${args[@]}" 2>>"$MC_LOG")"
    STANDING_HASH="$hash"
    STANDING_LINKS="$links"
    STANDING_BYTES="$nbytes"
    STANDING_STATUS="ready"
}

# mc_wrap_context TEXT -- prints `{"hookSpecificOutput": {"hookEventName":
# "SessionStart", "additionalContext": TEXT}}` on stdout, or nothing if the
# python call itself fails (fail-open, same as every other JSON build in
# this file). Shared by every branch below that injects, so the envelope
# shape is written exactly once.
mc_wrap_context() {
    env PYTHONPATH= "$MC_PY" -c '
import json, sys
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": sys.argv[1]}}))
' "$1" 2>>"$MC_LOG"
}

case "${SOURCE:-}" in
    startup|resume|clear)
        CODE_SHA="$(mc_git_head "${MEMCONTINUUM_CODE_ROOT:-}")"
        STORE_SHA="$(mc_git_head "${MEMCONTINUUM_ROOT:-}")"
        # Design R5 (audit MC-P1-05, TOP-0123 L5): start_code_sha stays
        # (first root, kept for older readers) AND start_code_shas
        # ({root: sha}) is added for every configured root -- one extra
        # python spawn (mc_code_roots, memlib.sh), the per-root git HEADs
        # (mc_git_head, no python) folded into the SAME state-update
        # transform below, no additional spawn for the map itself. LOW-3
        # (task-7-review.md): the per-root loop itself now lives once in
        # memlib.sh's mc_code_heads_from.
        CODE_HEADS="$(mc_code_heads_from "$(mc_code_roots)")"
        export MC_CODE_SHA="$CODE_SHA"
        export MC_STORE_SHA="$STORE_SHA"
        export MC_CODE_HEADS="$CODE_HEADS"
        export MC_SESSION_ID="$SESSION_ID"
        export MC_PROJECT_ENV="$MC_PROJECT"
        export MC_SOURCE="${SOURCE:-}"

        mc_update_state_json "$STATE_FILE" '
import os, time

# INC-0108: clear discards whatever this session_id had on disk before the
# setdefault init below runs, EXCEPT ledger -- see the header comment
# above for why the ledger alone survives. Design R6 (audit MC-P1-04,
# TOP-0123 L6): shell_baseline (the shell-diff branch own per-root
# baseline map) is kept alongside it for the same reason -- wiping it
# would silently re-baseline every root on the next Bash call, losing the
# distinction between pre- and post-clear shell dirt for the rest of the
# session.
if os.environ.get("MC_SOURCE") == "clear":
    _prior_ledger = state.get("ledger") or []
    _prior_shell_baseline = state.get("shell_baseline") or {}
    state = {}
    state["ledger"] = _prior_ledger
    state["shell_baseline"] = _prior_shell_baseline

_code_heads = {}
for _line in (os.environ.get("MC_CODE_HEADS") or "").splitlines():
    if _line and "\t" in _line:
        _root, _sha = _line.split("\t", 1)
        _code_heads[_root] = _sha

state.setdefault("session_id", os.environ.get("MC_SESSION_ID", ""))
state.setdefault("project", os.environ.get("MC_PROJECT_ENV", ""))
state.setdefault("start_code_sha", os.environ.get("MC_CODE_SHA", ""))
state.setdefault("start_code_shas", _code_heads)
# TOP-0122 L1 rule 2a (the commit nudge): last_seen_heads is a SEPARATE,
# per-PROMPT baseline (userprompt-remind.sh advances it turn by turn),
# distinct from the per-SESSION start_code_shas above -- seeded from the
# same current-HEAD map. clear (INC-0108, see the header comment) rebuilds
# state to just {ledger, shell_baseline} before this setdefault block
# runs, so a clear re-seeds last_seen_heads (and nudged_commits) from the
# CURRENT heads exactly like start_code_shas, never carrying either across
# a clear -- a commit already nudged before the clear is simply eligible
# again if that root HEAD ever revisits that sha, which is moot once
# last_seen_heads itself has just been reset to the current HEAD.
state.setdefault("last_seen_heads", dict(_code_heads))
state.setdefault("nudged_commits", [])
state.setdefault("start_store_sha", os.environ.get("MC_STORE_SHA", ""))
state.setdefault("created_at", time.time())
state.setdefault("ledger", [])
state.setdefault("user_turn_count", 0)
state.setdefault("last_inject_turn", -999)
state.setdefault("last_inject_time", 0)
state.setdefault("last_inject_ts", 0)
state.setdefault("last_injected_pairs", [])
# Look-back addendum (docs/DESIGN.md 2026-08-30):
# last_growth_turn baselines to turn 0 (session start, in turn-space);
# last_growth_ts baselines to this same moment in wall-clock terms
# (created_at), never to epoch 0 -- an epoch-0 default would make the
# 20-minute branch fire on turn 1 of every session.
state.setdefault("last_growth_turn", 0)
state.setdefault("last_growth_ts", state["created_at"])
state.setdefault("lookback_count", 0)

print(json.dumps(state))
' >>"$MC_LOG" 2>&1

        mc_prune_old_state "$MC_PROJECT" 1440

        # eval-topic-logging section 5 (owner-approved add-on): rotation
        # lives here, once per session at the session-INIT boundary
        # (startup/resume/clear) only -- never on mc_log's own append
        # path, and never re-checked on a mid-session `compact` (see
        # hooks/memlib.sh's mc_rotate_hook_log for the mechanics and the
        # fail-open/race-safety discussion).
        mc_rotate_hook_log

        # TOP-0132 L2: computed AFTER every state mutation above (init,
        # prune, rotate) -- a watchdog kill during mc_compute_standing's
        # own subprocess calls then loses only the digest, never the
        # session-init bookkeeping those already-committed writes hold.
        mc_compute_standing
        STANDING_CTX=""
        STANDING_LOG_TOKEN="$STANDING_STATUS"
        if [ "$STANDING_STATUS" = "ready" ]; then
            # Dedupe by hash, compare-and-set inside ONE locked transform
            # (never a plain read here followed by a separate write below
            # -- two concurrent SessionStart fires for this session could
            # otherwise both read the old hash and both decide "inject").
            # `clear` already rebuilt `state` to just {ledger,
            # shell_baseline} earlier in THIS SAME case arm, so it never
            # carries a stale standing_hash into this comparison --
            # `state.get("standing_hash")` is unset post-clear and never
            # equals a real hash, so clear always injects (when there is
            # something to inject) without needing its own branch here.
            export MC_STANDING_HASH="$STANDING_HASH"
            STANDING_VERDICT_TMP="$(mktemp 2>/dev/null)"
            export MC_STANDING_VERDICT_OUT="${STANDING_VERDICT_TMP:-}"
            mc_update_state_json "$STATE_FILE" '
import os

_new_hash = os.environ.get("MC_STANDING_HASH", "")
_verdict = "dedup"
if state.get("standing_hash") != _new_hash:
    state["standing_hash"] = _new_hash
    _verdict = "inject"
_out = os.environ.get("MC_STANDING_VERDICT_OUT")
if _out:
    try:
        with open(_out, "w") as _f:
            _f.write(_verdict)
    except OSError:
        pass

print(json.dumps(state))
' >>"$MC_LOG" 2>&1
            STANDING_VERDICT="inject"
            if [ -n "${STANDING_VERDICT_TMP:-}" ] && [ -s "$STANDING_VERDICT_TMP" ]; then
                STANDING_VERDICT="$(cat "$STANDING_VERDICT_TMP")"
            fi
            rm -f "${STANDING_VERDICT_TMP:-}" 2>/dev/null
            if [ "$STANDING_VERDICT" = "inject" ]; then
                STANDING_CTX="$STANDING_TEXT"
                STANDING_LOG_TOKEN="injected links=$STANDING_LINKS bytes=$STANDING_BYTES hash=$STANDING_HASH"
            else
                STANDING_LOG_TOKEN="dedup"
            fi
        fi

        if [ -n "$STANDING_CTX" ]; then
            PY_OUT="$(mc_wrap_context "$STANDING_CTX")"
            [ -n "$PY_OUT" ] && printf '%s\n' "$PY_OUT"
        fi

        finish "init" "standing=$STANDING_LOG_TOKEN"
        ;;

    compact)
        # TOP-0132 L2: attempted on EVERY compact -- unlike startup/resume
        # it never dedup-skips (the context is gone after compaction), and
        # unlike coverage/look-back below it needs no pre-existing state
        # file (only their own `pending` read does). Computed before the
        # "no state" early-exit so that exit can still carry the digest.
        mc_compute_standing
        STANDING_CTX=""
        STANDING_LOG_TOKEN="$STANDING_STATUS"
        if [ "$STANDING_STATUS" = "ready" ]; then
            STANDING_CTX="$STANDING_TEXT"
            STANDING_LOG_TOKEN="injected links=$STANDING_LINKS bytes=$STANDING_BYTES hash=$STANDING_HASH"
            if [ -f "$STATE_FILE" ]; then
                export MC_STANDING_HASH="$STANDING_HASH"
                mc_update_state_json "$STATE_FILE" '
import os
state["standing_hash"] = os.environ.get("MC_STANDING_HASH", "")
print(json.dumps(state))
' >>"$MC_LOG" 2>&1
            fi
        fi

        if [ ! -f "$STATE_FILE" ]; then
            if [ -n "$STANDING_CTX" ]; then
                PY_OUT="$(mc_wrap_context "$STANDING_CTX")"
                [ -n "$PY_OUT" ] && printf '%s\n' "$PY_OUT"
            fi
            finish "compact-no-state" "standing=$STANDING_LOG_TOKEN"
        fi

        OUTPUT_JSON="$(MEMCONTINUUM_ROOT="${MEMCONTINUUM_ROOT:-}" env PYTHONPATH= "$MC_PY" -c '
import json, os, sys

try:
    with open(sys.argv[1]) as f:
        state = json.load(f)
    if not isinstance(state, dict):
        state = {}
except Exception:
    state = {}

pending = state.get("pending") or {}
if not pending:
    sys.exit(3)

unmapped = pending.get("unmapped") or []
coverage_status = pending.get("coverage_status", "unknown")
code_changed = pending.get("code_head_changed")
store_changed = pending.get("store_head_changed")


def yn(v):
    if v is None:
        return "unknown"
    return "yes" if v else "no"


if coverage_status != "ok":
    fact_line = (
        "Coverage signal — decision-topic coverage unknown "
        f"(store index {coverage_status}); code HEAD changed: {yn(code_changed)}; "
        f"store HEAD changed: {yn(store_changed)}"
    )
    has_evidence = bool(code_changed) or bool(store_changed)
else:
    n = len(unmapped)
    shown = unmapped[:8]
    extra = n - len(shown)
    paths_line = ", ".join(shown) if shown else "(none)"
    if extra > 0:
        paths_line += f", +{extra}"
    fact_line = (
        f"Coverage signal — {n} edited file(s) with no decision topic: {paths_line}; "
        f"code HEAD changed: {yn(code_changed)}; store HEAD changed: {yn(store_changed)}"
    )
    has_evidence = (n > 0) or bool(code_changed) or bool(store_changed)

if not has_evidence:
    sys.exit(3)

store_root = os.environ.get("MEMCONTINUUM_ROOT") or "<store root not configured>"
question = (
    "Any ruling, incident, or rejected alternative from this session that "
    "the MemContinuum store should hold? Store: " + store_root + " — a ruling "
    "is a new link in topics/<area>/<topic>.md, an incident is a file in "
    "incidents/ (see docs/SCHEMA.md); NOT Claude Code auto-memory. If none, "
    "say so once."
)
ctx = fact_line + "\n\n" + question
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": ctx,
    }
}))
' "$STATE_FILE" 2>>"$MC_LOG")"
        RC=$?

        # Look-back compact twin: only evaluated (and only reads pending,
        # never mutates it) when coverage found no evidence above. Coverage
        # always wins; this must run BEFORE pending is cleared below.
        LB_JSON=""
        LB_RC=3
        LB_SINCE=""
        LB_TURN=""
        if [ $RC -ne 0 ]; then
            LB_META_TMP="$(mktemp 2>/dev/null)"
            LB_JSON="$(MEMCONTINUUM_ROOT="${MEMCONTINUUM_ROOT:-}" env PYTHONPATH= "$MC_PY" -c '
import json, os, sys

try:
    with open(sys.argv[1]) as f:
        state = json.load(f)
    if not isinstance(state, dict):
        state = {}
except Exception:
    state = {}

pending = state.get("pending") or {}
if not pending:
    sys.exit(3)

turn = pending.get("user_turn_count", 0)
last_growth_turn = pending.get("last_growth_turn", 0)
since = turn - last_growth_turn
if since < 3:
    sys.exit(3)

Q = chr(39)
store_root = os.environ.get("MEMCONTINUUM_ROOT") or "<store root not configured>"
fact = (
    f"Look-back signal — {since} user turns with no edited-file evidence; "
    "context was just compacted."
)
question = (
    "Did the conversation since then establish any ruling, incident, "
    "rejected alternative, priority, wording choice, money decision, or "
    f"{Q}not now{Q} that the MemContinuum store should hold? Store: "
    + store_root + " — a ruling is a new link in topics/<area>/<topic>.md, "
    "an incident is a file in incidents/ (see docs/SCHEMA.md); NOT Claude "
    "Code auto-memory. If none, say so once."
)
ctx = fact + "\n\n" + question
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": ctx,
    }
}))
print(f"{turn} {since}", file=sys.stderr)
' "$STATE_FILE" 2>"${LB_META_TMP:-/dev/null}")"
            LB_RC=$?
            if [ -n "${LB_META_TMP:-}" ] && [ -s "$LB_META_TMP" ]; then
                read -r LB_TURN LB_SINCE < "$LB_META_TMP" 2>/dev/null
            fi
            rm -f "${LB_META_TMP:-}" 2>/dev/null
        fi

        # Consume pending unconditionally (idempotent no-op if already empty)
        # so a compact source never re-injects the same evidence twice; when
        # the look-back twin fired, also stamp last_inject_turn/last_inject_ts
        # AND last_inject_time (dual-gate review finding 4 -- coverage's own
        # cooldown clock, so a per-turn coverage candidate right after this
        # compact doesn't read a stale/zero last_inject_time and fire
        # straight through the cooldown that is meant to follow any
        # injection) in this same locked update so the very next per-turn
        # hook call requires a full new thin stretch rather than immediately
        # re-firing.
        LB_COUNT=""
        if [ $LB_RC -eq 0 ] && [ -n "$LB_JSON" ]; then
            export MC_LB_TURN="$LB_TURN"
            mc_update_state_json "$STATE_FILE" '
import os, time

state["pending"] = {}
try:
    turn = int(os.environ.get("MC_LB_TURN") or 0)
except Exception:
    turn = 0
now = time.time()
state["last_inject_turn"] = turn
state["last_inject_time"] = now
state["last_inject_ts"] = now
state["lookback_count"] = state.get("lookback_count", 0) + 1

print(json.dumps(state))
' >>"$MC_LOG" 2>&1
            # dual-gate review finding 7: lookback_count is tracked but was
            # never logged -- read it back (cheap, one extra call; this
            # hook has no overall-budget constraint) so the outcome line
            # below can include it.
            LB_COUNT="$(env PYTHONPATH= "$MC_PY" -c '
import json, sys
with open(sys.argv[1]) as f:
    state = json.load(f)
print(state.get("lookback_count", 0))
' "$STATE_FILE" 2>>"$MC_LOG")"
        else
            mc_update_state_json "$STATE_FILE" '
state["pending"] = {}
print(json.dumps(state))
' >>"$MC_LOG" 2>&1
        fi

        # Merge: coverage's own ctx (if RC==0) else look-back's (if
        # LB_RC==0) else nothing, THEN the standing digest appended after
        # it -- coverage (and, failing that, look-back) stays first when
        # it has evidence; standing is delivered every compact regardless
        # (computed above, unconditionally). One python call does the
        # whole merge -- it never re-derives coverage/look-back's own
        # ctx text, only lifts it back out of the JSON those two branches
        # above already built, so this can never disagree with what they
        # actually decided.
        MERGE_META_TMP="$(mktemp 2>/dev/null)"
        FINAL_JSON="$(env PYTHONPATH= "$MC_PY" -c '
import json, sys


def ctx_of(raw):
    if not raw:
        return None
    try:
        obj = json.loads(raw)
    except Exception:
        return None
    return obj.get("hookSpecificOutput", {}).get("additionalContext")


output_json, lb_json, standing_ctx = sys.argv[1], sys.argv[2], sys.argv[3]

base = ctx_of(output_json)
kind = "coverage" if base is not None else None
if base is None:
    base = ctx_of(lb_json)
    kind = "lookback" if base is not None else None

parts = [p for p in (base, standing_ctx or None) if p]
final = "\n\n".join(parts)
if final:
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": final}}))
print(kind or "none", file=sys.stderr)
' "$OUTPUT_JSON" "$LB_JSON" "$STANDING_CTX" 2>"${MERGE_META_TMP:-/dev/null}")"
        MERGE_KIND="none"
        if [ -n "${MERGE_META_TMP:-}" ] && [ -s "$MERGE_META_TMP" ]; then
            read -r MERGE_KIND <"$MERGE_META_TMP" 2>/dev/null
        fi
        rm -f "${MERGE_META_TMP:-}" 2>/dev/null

        [ -n "$FINAL_JSON" ] && printf '%s\n' "$FINAL_JSON"

        case "$MERGE_KIND" in
            coverage) finish "compact-injected" "standing=$STANDING_LOG_TOKEN" ;;
            lookback) finish "compact-lookback" "turn=$LB_TURN since=$LB_SINCE count=${LB_COUNT:-0} standing=$STANDING_LOG_TOKEN" ;;
            *) finish "compact-no-evidence" "standing=$STANDING_LOG_TOKEN" ;;
        esac
        ;;

    *)
        finish "source-not-handled"
        ;;
esac
