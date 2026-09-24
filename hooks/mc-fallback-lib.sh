#!/usr/bin/env bash
# mc-fallback-lib.sh -- shared plumbing for the search-fallback channel
# (TOP-0133 L1), sourced by BOTH hooks/pre-edit-chain.sh and hooks/
# newfile-nudge.sh. Re-gate round 3 (owner's duplication rule -- "you see
# it, you kill it"): the ~55-line JSON/reason parser and the
# search_fallbacks state-write transform used to be inline, verbatim, in
# both hook scripts, differing only in whether the rendered text needed
# the PreToolUse `hookSpecificOutput` envelope wrapped around it
# (pre-edit-chain.sh) or not (newfile-nudge.sh, which splices the plain
# text into its own, differently-shaped reminder message). Both concerns
# now live here, parameterised by that one difference plus the outcome-
# line "hook" name each caller's own state entries are tagged with.
#
# Pure functions/side-effect-scoped helpers, same discipline as hooks/
# mc-query-lib.sh's own header: no MEMCONTINUUM_* defaulting of its own
# (callers pass everything explicit), safe to source unconditionally.
# bash-3.2-safe throughout (macOS CI): no arrays-as-return-values, no
# associative arrays -- plain global-variable "out params" (FB_HITS,
# FB_IDS, FB_TEXT, FB_HITS_FOR_STATE, FB_REASON), the same convention the
# original inline code already used before this refactor.

# MC_FB_LABEL_FILE / MC_FB_LABEL_PROMPT (TOP-0133 L2, owner's duplication
# rule -- "you see it, you kill it"): the L1 label used to be duplicated
# verbatim in pre-edit-chain.sh and newfile-nudge.sh; both now reference
# this ONE constant instead. MC_FB_LABEL_PROMPT is L2's own label (same
# shape -- a guess, never a match -- adapted wording: a prompt has no file
# to name).
MC_FB_LABEL_FILE='No recorded decision binds this file. Nearest by search -- may be unrelated:'
MC_FB_LABEL_PROMPT="Nearest recorded decision by search on this prompt's words -- may be unrelated:"

# mc_fallback_parse PY RC LABEL WANT_ENVELOPE RAW_JSON [EXCLUDE_IDS] [MAX_HITS]
#
# Runs the search-fallback result parser (one python process) and sets,
# as plain (non-local, so the caller reads them back) shell variables:
#   FB_HITS            -- hit count as a decimal string ("0" on none)
#   FB_IDS              -- comma-joined hit ids
#   FB_TEXT             -- WANT_ENVELOPE=1: the full PreToolUse
#                          hookSpecificOutput JSON envelope, ready to
#                          print as-is. WANT_ENVELOPE=0: the bare
#                          "<label>\n\n<chain_text>[...]" text, for a
#                          caller that splices it into its OWN message
#                          shape instead (newfile-nudge.sh).
#   FB_HITS_FOR_STATE   -- JSON array of {"id","title"} for the state
#                          write below; "" when there were no hits.
#   FB_REASON           -- "" on a real hit, else one of: a state name
#                          lifted off the search envelope (missing/
#                          uninitialized/index-needs-migration/
#                          quarantined/stale), "search-failed rc=N" (RC
#                          was non-zero), "bad-json" (RC==0 but stdout
#                          didn't parse), "already-surfaced" (parsed fine,
#                          every hit was in EXCLUDE_IDS), or "no-hits"
#                          (parsed fine, zero real hits, no state worth
#                          naming).
#
# RC is the exit code of the search subprocess that produced RAW_JSON
# (its stdout, possibly empty). Runs even when RAW_JSON is empty -- a
# genuine crash with nothing on stdout still needs `reason=search-failed
# rc=N` named (re-gate round 1 fix: the old gate only ran this parser
# when stdout was non-empty, silently defaulting a crash to "no-hits").
#
# EXCLUDE_IDS (TOP-0133 L2, optional 6th arg): a comma-joined set of hit
# ids to skip entirely -- never counted, never rendered, never added to
# FB_HITS_FOR_STATE -- so a caller (userprompt-remind.sh's prompt-query
# channel) can ask for "the first hit not already surfaced this session"
# off the SAME one search call, with no second query. Omitted/empty
# excludes nothing -- byte-identical to the 5-arg form (see
# test_mc_fallback_parse_five_arg_form_unchanged).
#
# MAX_HITS (optional 7th arg): stop accepting hits once this many have
# survived the exclude filter. Omitted/empty/non-positive means "all" --
# the 5-arg form's own unbounded behavior (pre-edit-chain.sh/
# newfile-nudge.sh's own `--limit 2` already bounds the search call
# itself, so neither existing caller has ever needed this).
mc_fallback_parse() {
    local _py="$1" _rc="$2" _label="$3" _want_envelope="$4" _raw="$5"
    local _exclude_ids="${6:-}" _max_hits="${7:-}"
    FB_HITS=""
    FB_IDS=""
    FB_TEXT=""
    FB_HITS_FOR_STATE=""
    FB_REASON=""
    export HOOK_FB_LABEL="$_label"
    export MC_FB_RC="$_rc"
    export MC_FB_WANT_ENVELOPE="$_want_envelope"
    export MC_FB_EXCLUDE_IDS="$_exclude_ids"
    export MC_FB_MAX_HITS="$_max_hits"
    {
        IFS= read -r -d '' FB_HITS
        IFS= read -r -d '' FB_IDS
        IFS= read -r -d '' FB_TEXT
        IFS= read -r -d '' FB_HITS_FOR_STATE
        IFS= read -r -d '' FB_REASON
    } < <(printf '%s' "$_raw" | PYTHONPATH= "$_py" -c '
import json, os, sys

rc = int(os.environ.get("MC_FB_RC", "1") or "1")
want_envelope = os.environ.get("MC_FB_WANT_ENVELOPE", "0") == "1"
exclude_ids = {x for x in (os.environ.get("MC_FB_EXCLUDE_IDS", "") or "").split(",") if x}
try:
    max_hits = int(os.environ.get("MC_FB_MAX_HITS", "") or "0")
except ValueError:
    max_hits = 0
raw = sys.stdin.read()

d = None
if raw:
    try:
        d = json.loads(raw)
    except Exception:
        d = None

hits = []
state = None
reason = ""
if rc != 0:
    if isinstance(d, dict):
        reason = d.get("reason") or d.get("state") or ""
    if not reason:
        reason = f"search-failed rc={rc}"
elif d is None:
    reason = "bad-json"
else:
    if isinstance(d, dict):
        state = d.get("state")
        hits = d.get("results", [])
    elif isinstance(d, list):
        hits = d
    if not isinstance(hits, list):
        hits = []

label = os.environ.get("HOOK_FB_LABEL", "")
chain_texts = []
ids = []
for_state = []
any_excluded = False
for h in hits:
    if not isinstance(h, dict):
        continue
    ct = h.get("chain_text", "") or ""
    if not ct:
        continue
    hid = str(h.get("id", ""))
    if hid in exclude_ids:
        any_excluded = True
        continue
    ids.append(hid)
    chain_texts.append(ct)
    for_state.append({"id": hid, "title": str(h.get("title", "") or "")})
    if max_hits > 0 and len(chain_texts) >= max_hits:
        break

if not chain_texts and not reason:
    if state in ("quarantined", "stale"):
        reason = state
    elif any_excluded:
        reason = "already-surfaced"
    else:
        reason = "no-hits"

if not chain_texts:
    fields = ("0", "", "", "", reason)
else:
    text = label + "\n\n" + "\n\n".join(chain_texts)
    if want_envelope:
        text = json.dumps({
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "additionalContext": text,
            }
        })
    fields = (str(len(chain_texts)), ",".join(ids), text, json.dumps(for_state), "")

for field in fields:
    sys.stdout.write(field.replace(chr(0), ""))
    sys.stdout.write(chr(0))
' 2>/dev/null)
}

# mc_fallback_write_state STATE_FILE FILE_PATH HITS_JSON HOOK_NAME [DEADLINE_SECONDS]
#
# Appends each (id, title) pair in HITS_JSON to STATE_FILE's own
# `search_fallbacks` list, deduped by (FILE_PATH, id) with the position
# refreshed on a repeat (never a growing run of near-duplicates for the
# same repeated miss), each title truncated to 120 characters, capped at
# the last 20 entries -- see hooks/pre-edit-chain.sh's own prior comment
# for the full look-back rationale. Requires hooks/memlib.sh already
# sourced (mc_update_state_json, mc_state_file_for). DEADLINE_SECONDS
# defaults to mc_update_state_json's own default (2.0s) when omitted;
# the search fallback's own callers pass a short one (re-gate round 3,
# MAJOR 1) since this write runs under the SAME 2s watchdog budget the
# query itself already spent most of. Returns mc_update_state_json's own
# return value -- 0 on a written (or legitimately empty) update, 1 on a
# lock timeout/open failure, which the caller maps to its own `fb_state=
# skipped-lock` field rather than treating as fatal (the additionalContext
# guess itself is unaffected either way -- this is titling metadata only).
mc_fallback_write_state() {
    local state_file="$1" fb_file="$2" hits_json="$3" hook_name="$4" deadline_s="${5:-2.0}"
    export MC_FB_FILE="$fb_file"
    export MC_FB_HITS_JSON="$hits_json"
    export MC_FB_HOOK_NAME="$hook_name"
    mc_update_state_json "$state_file" '
import json, os

try:
    new_hits = json.loads(os.environ.get("MC_FB_HITS_JSON") or "[]")
except Exception:
    new_hits = []
if not isinstance(new_hits, list):
    new_hits = []

existing = state.get("search_fallbacks")
if not isinstance(existing, list):
    existing = []

fb_file = os.environ.get("MC_FB_FILE", "")
hook_name = os.environ.get("MC_FB_HOOK_NAME", "")

new_keys = set()
for h in new_hits:
    if isinstance(h, dict):
        new_keys.add((fb_file, str(h.get("id", ""))))
existing = [
    e for e in existing
    if not (isinstance(e, dict) and (e.get("file"), e.get("id")) in new_keys)
]
for h in new_hits:
    if not isinstance(h, dict):
        continue
    title = str(h.get("title", "") or "")[:120]
    existing.append({
        "file": fb_file,
        "id": str(h.get("id", "")),
        "title": title,
        "hook": hook_name,
    })
state["search_fallbacks"] = existing[-20:]
print(json.dumps(state))
' "$deadline_s"
}
