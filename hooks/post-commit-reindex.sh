#!/usr/bin/env bash
# git post-commit hook for the STORE repo (memory/, not this tool repo):
# reindexes the store's markdown into the derived SQLite index after every
# commit, so `search`/`chain`/`for-path` see the new content immediately
# instead of waiting for the next manual `reindex`.
#
# Symlink or copy this as .git/hooks/post-commit inside the store repo --
# see install-hooks.md.
#
# Design R8 (audit MC-P2-02, TOP-0123 L7): a full (embedding) reindex can
# take tens of seconds on a real store (measured ~40s for a 49-file store,
# cold process/warm fastembed cache) -- unacceptable inside a synchronous
# `git commit`. This hook now does two things instead of one:
#   1. A bounded CONTENT pass only (`reindex --no-embed --auto`), run
#      through the shared watchdog launcher (hooks/mc-watchdog.sh) under
#      MEMCONTINUUM_POST_COMMIT_BUDGET (default 30s) -- text content is
#      always current the moment this hook returns; nothing here ever
#      calls the embedding backend, so a hung/slow embedding backend can
#      never delay a commit.
#   2. When the content pass leaves records without a fresh vector, this
#      hook touches a per-project marker file and spawns a detached
#      `embed-worker` subcommand (Python subprocess.Popen with a new
#      session -- never bash `&`, never a `setsid` binary, which macOS
#      does not ship) that backfills embeddings in the background and
#      coalesces repeated commits into one pass. See `memidx.py
#      embed-worker --help` and docs/INTERNALS.md's watchdog/embedding-
#      lifecycle sections for the full lock/marker/crash contract.
#
# After the reindex pass, the same guarded child does two more things, in
# this order (each section is unable to change the exit code, and the hook
# still writes ONE hook.log line, now carrying `relint=... backup=...`):
#   3. RE-LINT. `git commit --no-verify` skips pre-commit but not
#      post-commit, so the two checks pre-commit-append-only.sh runs (schema;
#      append-only against the parent) run again here via the shared
#      hooks/mc-store-lint.sh. A finding never blocks (the commit exists):
#      it prints a banner on stderr, logs `relint=failed:<kind>` and leaves a
#      sticky `$MEMCONTINUUM_HOME/<project>.relint-failed` marker that
#      sessionstart-remind.sh surfaces; the next clean run removes it.
#   4. BACKUP. When MEMCONTINUUM_BACKUP_DIR is set, `git bundle create --all`
#      into `<dir>/<project>/`, verified, with a MANIFEST.txt line, pruned to
#      the newest MEMCONTINUUM_BACKUP_KEEP. See hooks/install-hooks.md.
#
# Env (same names/defaults as pre-edit-chain.sh):
#   MEMCONTINUUM_ROOT     the store's markdown root to reindex. Required --
#                     unlike the pre-edit hook, this one DOES pass it to
#                     memidx.py, as `reindex --root`.
#   MEMCONTINUUM_PROJECT  project namespace. Defaults to $(basename "$MEMCONTINUUM_ROOT"),
#                     else "default". The literal project-name default lives
#                     only in project wiring, never in this script.
#   MEMCONTINUUM_HOME     passed through to memidx.py unchanged; also where this
#                     script's own log line, the embed marker/lock/log, and
#                     the index db all live. Defaults to ~/.memcontinuum,
#                     matching memidx.py's default. Resolved (with the
#                     config.sh pointer-chain fallback) by hooks/mc-watchdog.sh
#                     below -- not duplicated in this file.
#   MEMCONTINUUM_PYTHON   absolute path to the venv python. Falls back to
#                     $MEMCONTINUUM_HOME/config.sh (if it sets MEMCONTINUUM_PYTHON),
#                     then <engine>/.venv/bin/python (scripts/repo-init.sh
#                     --bootstrap-venv) when unset.
#   MEMCONTINUUM_BACKUP_DIR   absolute, ALREADY EXISTING directory for store
#                     backup bundles; unset/empty = backups off. Environment
#                     first, then $MEMCONTINUUM_HOME/config.sh (sourced by
#                     mc-watchdog.sh above; memcontinuum-setup.sh --backup-dir
#                     writes it). Never created by this hook: an unmounted
#                     drive must not silently receive bundles on the root fs.
#   MEMCONTINUUM_BACKUP_KEEP  how many bundles to keep per store (default 10).
#   MEMCONTINUUM_POST_COMMIT_BUDGET  wall-clock budget in seconds for the
#                     content pass (default 30). Passed to the shared
#                     watchdog launcher as MC_WATCHDOG_BUDGET.
#   MEMCONTINUUM_EMBED_WORKER  set to "0" to disable spawning the
#                     background embed-worker entirely (tests/CI use this
#                     where a detached background process would outlive
#                     the run) -- the marker is still touched, so `stats`/
#                     `check --json` still show the backlog; nothing
#                     backfills it until a worker is run by hand or a
#                     later commit spawns one with this unset.

set -u
export PYTHONPATH=

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
MEMIDX="$SCRIPT_DIR/../memidx.py"

# Watchdog guard (design R8): must be the literal first thing after
# resolving SCRIPT_DIR and sourcing mc-watchdog.sh, same position/reasoning
# as every other guarded hook (see mc-watchdog.sh's own header and
# precompact-persist.sh's identical block). mc-watchdog.sh's sourced tail
# resolves MEMCONTINUUM_HOME itself (default, then the config.sh pointer
# chain -- the same steps this file used to duplicate inline) and exports
# it, so nothing else in this file needs to repeat that chain; it also
# resolves MC_GUARD_PY via the same $MEMCONTINUUM_PYTHON -> config.sh ->
# engine-venv order PY below uses. Budget defaults to 30s here (a real
# content pass is measured well under 1s; 30s is generous headroom for a
# slow filesystem, not a tuned ceiling) -- set before the guard so the
# launcher (which reads MC_WATCHDOG_BUDGET from the environment) sees it.
# shellcheck source=mc-watchdog.sh
source "${MC_WATCHDOG_LIB_PATH:-$SCRIPT_DIR/mc-watchdog.sh}" 2>/dev/null
MC_NO_WATCHDOG=0
if [ -z "${MC_UNDER_TIMEOUT:-}" ]; then
    export MC_UNDER_TIMEOUT=1
    export MC_WATCHDOG_BUDGET="${MEMCONTINUUM_POST_COMMIT_BUDGET:-30}"
    if [ -x "${MC_GUARD_PY:-}" ] && [ -n "${MC_WATCHDOG_LAUNCHER_PY:-}" ]; then
        "$MC_GUARD_PY" -c "$MC_WATCHDOG_LAUNCHER_PY" "${BASH:-bash}" "${BASH_SOURCE[0]}" "$@"
        exit 0
    fi
    # No guard python resolved: this run is NOT under a watchdog. The
    # re-lint and backup sections below do git/filesystem work that must
    # never run unwatched, so they log skipped:no-watchdog and do nothing.
    MC_NO_WATCHDOG=1
fi

# The lint functions and the backup helpers live in sibling files; a failed
# load is infrastructure, so the sections below skip (fail open), never abort.
MC_NO_LINT_LIB=0
# shellcheck source=mc-store-lint.sh
source "${MC_STORE_LINT_LIB_PATH:-$SCRIPT_DIR/mc-store-lint.sh}" 2>/dev/null || MC_NO_LINT_LIB=1
# shellcheck source=../scripts/mc-registry-lib.sh
source "$SCRIPT_DIR/../scripts/mc-registry-lib.sh" 2>/dev/null || true

# From here on: the guarded child. MEMCONTINUUM_HOME is already resolved
# and exported by mc-watchdog.sh above.
MEMCONTINUUM_HOME="${MEMCONTINUUM_HOME:-$HOME/.memcontinuum}"
PY="${MEMCONTINUUM_PYTHON:-$SCRIPT_DIR/../.venv/bin/python}"
LOG="$MEMCONTINUUM_HOME/hook.log"

mkdir -p "$MEMCONTINUUM_HOME" 2>/dev/null

if [ -z "${MEMCONTINUUM_ROOT:-}" ]; then
    # Can't derive PROJECT the normal way (basename of a ROOT we don't
    # have) -- fall back to MEMCONTINUUM_PROJECT/"default", same as every
    # other hook's fallback chain, so this line still carries project=
    # (round-2 review finding: "every hook.log line carries project=" was
    # still false for this one).
    _SKIP_PROJECT="${MEMCONTINUUM_PROJECT:-default}"
    printf '%s post-commit-reindex: MEMCONTINUUM_ROOT not set, skipping project=%s\n' \
        "$(date -Iseconds 2>/dev/null || date)" "$_SKIP_PROJECT" >>"$LOG" 2>/dev/null || true
    exit 0
fi

PROJECT="${MEMCONTINUUM_PROJECT:-$(basename "$MEMCONTINUUM_ROOT")}"

# ONE validation of the two values that become path segments, before ANY
# project-derived path ($PROJECT.sqlite, .relint-failed, <dir>/$PROJECT) is
# built. A hand-edited wrapper with MEMCONTINUUM_PROJECT=../victim must not
# write or delete outside MEMCONTINUUM_HOME.
#   PATH_UNSAFE   $PROJECT could leave its directory (empty, ., .., a slash,
#                 or a control character): the hook logs and touches nothing.
#   BAD_PROJECT   $PROJECT is outside [A-Za-z0-9._-]+ (e.g. a space): the
#                 reindex still runs (it only names files inside HOME), but the
#                 re-lint marker and the backup folder are skipped.
#   BAD_DIR       MEMCONTINUUM_BACKUP_DIR is not absolute or holds a control
#                 character (a newline would split a path): backup skipped.
PATH_UNSAFE=0
BAD_PROJECT=0
BAD_DIR=0
case "$PROJECT" in
    ""|.|..|*/*|*[[:cntrl:]]*) PATH_UNSAFE=1; BAD_PROJECT=1 ;;
    *[!A-Za-z0-9._-]*) BAD_PROJECT=1 ;;
esac
case "${MEMCONTINUUM_BACKUP_DIR:-}" in
    "") ;;
    *[[:cntrl:]]*) BAD_DIR=1 ;;
    /*) ;;
    *) BAD_DIR=1 ;;
esac
if [ "$PATH_UNSAFE" -eq 1 ]; then
    printf '%s post-commit-reindex: bad project name, skipping project=%s root=%s relint=skipped:bad-project backup=skipped:bad-project\n' \
        "$(date -Iseconds 2>/dev/null || date)" "$(printf '%s' "$PROJECT" | tr -d '[:cntrl:]')" "$MEMCONTINUUM_ROOT" >>"$LOG" 2>/dev/null || true
    exit 0
fi
DB_PATH="$MEMCONTINUUM_HOME/$PROJECT.sqlite"

# $EPOCHREALTIME is a bash 5-ism (unbound under `set -u` on macOS's stock
# bash 3.2); `date +%s` (whole seconds -- nothing downstream parses the
# elapsed value, so the lost sub-second precision costs nothing) is the
# portable substitute, matching BSD date (no `%N`) same as GNU date.
START_TS=$(date +%s 2>/dev/null || echo 0)
# Design R8: `--no-embed --auto` -- content only, never the embedding
# backend, so this call can never hang on a slow/broken embedding model.
# `cmd_reindex` prints "N record(s) awaiting embedding" at the end of its
# summary line whenever a row's vector is missing, stale, or from a
# different fingerprint -- parsed below into EMBED_STATE.
OUT="$(PYTHONPATH= "$PY" "$MEMIDX" reindex --root "$MEMCONTINUUM_ROOT" --project "$PROJECT" --db "$DB_PATH" --no-embed --auto 2>&1)"
RC=$?
NOW_TS=$(date +%s 2>/dev/null || echo "$START_TS")
ELAPSED=$(( NOW_TS - START_TS ))

# Parse "N record(s) awaiting embedding" off the end of the summary line
# without `[[ =~ ]]` (bash-3.2-safe: plain case/parameter expansion only).
# EMBED_STATE defaults to "skipped" -- the content pass failed (a non-zero
# rc, e.g. an integrity failure) or was killed by the watchdog before it
# ever printed a summary line at all (in the killed case, this file's own
# printf below never even runs -- the launcher already wrote its own
# `outcome=watchdog-killed hook=post-commit-reindex.sh` line and exited).
EMBED_STATE="skipped"
E=""
if [ "$RC" -eq 0 ]; then
    case "$OUT" in
        *"record(s) awaiting embedding")
            TAIL="${OUT##*, }"
            E="${TAIL%% *}"
            ;;
    esac
    case "$E" in
        ''|*[!0-9]*) E="" ;;
    esac
    if [ -n "$E" ]; then
        if [ "$E" -gt 0 ]; then
            EMBED_STATE="pending"
        else
            EMBED_STATE="clean"
        fi
    fi
fi

if [ "$EMBED_STATE" = "pending" ]; then
    MARKER="$MEMCONTINUUM_HOME/$PROJECT.embed-pending"
    touch "$MARKER" 2>/dev/null || true
    if [ "${MEMCONTINUUM_EMBED_WORKER:-1}" != "0" ]; then
        LOGF="$MEMCONTINUUM_HOME/$PROJECT.embed.log"
        # Design R8: spawned from Python (subprocess.Popen with a new
        # session), never bash `&` and never a `setsid` binary (macOS
        # ships neither `setsid` nor `flock`/`timeout` -- see
        # docs/INTERNALS.md's watchdog section). The watchdog launcher
        # above kills the WHOLE process group of its guarded child on
        # timeout (or its own death) via `os.killpg` -- a plain `bash foo
        # &` job stays inside that same group and would die with it,
        # before ever getting to run. `start_new_session=True` puts this
        # worker in a brand-new process group/session that `killpg`
        # cannot reach, so a watchdog kill (or the launcher's own
        # unconditional post-success group sweep) can never take the
        # worker down with it. Uses "$PY" (this hook's own resolved
        # python, not sys.executable) as the WORKER's interpreter too, so
        # a test that points MEMCONTINUUM_PYTHON at a stub keeps that
        # same stub in the spawned worker.
        "$PY" -c '
import subprocess
import sys

py, memidx_path, root, project, db, log_path = sys.argv[1:7]
log = open(log_path, "ab")
subprocess.Popen(
    [py, memidx_path, "embed-worker", "--root", root, "--project", project, "--db", db],
    start_new_session=True,
    stdin=subprocess.DEVNULL,
    stdout=log,
    stderr=log,
    close_fds=True,
)
' "$PY" "$MEMIDX" "$MEMCONTINUUM_ROOT" "$PROJECT" "$DB_PATH" "$LOGF" >/dev/null 2>&1 || true
    fi
fi

# --- 3. post-commit re-lint (INC-0128) --------------------------------------
# Same two checks as pre-commit-append-only.sh, through the same shared
# functions (hooks/mc-store-lint.sh), so a `--no-verify` commit of a bad
# record is still named. Never blocks and never changes the exit code. The
# pre-commit hook's documented gaps are inherited unchanged: the schema pass
# reads the working tree, not the index. HEAD~1 vs the index is HEAD vs
# HEAD~1 here, because after a commit the index equals HEAD for the
# committed paths. A root commit (no HEAD~1) gets the schema pass only.
RELINT="skipped"
RELINT_MARKER="$MEMCONTINUUM_HOME/$PROJECT.relint-failed"
# mc_safe_replace SRC DST -- atomic rename that refuses a destination which is
# a symlink or a directory (mv would move SRC *into* either), and raises on a
# directory destination (os.replace). Returns non-zero on any refusal.
mc_safe_replace() {
    if [ -L "$2" ] || [ -d "$2" ]; then return 1; fi
    "$PY" -c 'import os, sys; os.replace(sys.argv[1], sys.argv[2])' "$1" "$2" 2>/dev/null
}
mc_post_commit_relint() {
    local memlint="$SCRIPT_DIR/../memlint.py" kind="" summary="" sha short root_phys mroot
    if [ "$MC_NO_WATCHDOG" -eq 1 ]; then
        RELINT="skipped:no-watchdog"
        return 0
    fi
    if [ "$BAD_PROJECT" -eq 1 ]; then
        RELINT="skipped:bad-project"
        return 0
    fi
    if [ "$MC_NO_LINT_LIB" -eq 1 ] || ! type mc_store_lint_schema >/dev/null 2>&1 \
            || ! type mc_physical >/dev/null 2>&1; then
        RELINT="skipped:no-lint-lib"
        return 0
    fi
    if [ ! -x "$PY" ]; then
        RELINT="skipped:no-python"
        return 0
    fi
    root_phys="$(mc_physical "$MEMCONTINUUM_ROOT")"
    mc_store_lint_schema "$PY" "$memlint" "$MEMCONTINUUM_ROOT"
    local append="ok" append_out=""
    if git -C "$MEMCONTINUUM_ROOT" rev-parse --verify -q HEAD~1 >/dev/null 2>&1; then
        mc_store_lint_append_only "$PY" "$memlint" "$MEMCONTINUUM_ROOT" HEAD~1
        append="$MC_LINT_APPEND"
        append_out="$MC_LINT_APPEND_OUT"
    fi
    # Exit 0 with no memlint summary line is no evidence of a clean store (a
    # stub interpreter, e.g. /bin/true): treat it like a crash.
    if [ "$MC_LINT_SCHEMA" = "ok" ] && [ "${MC_LINT_SCHEMA_SUMMARY:-0}" != "1" ]; then
        MC_LINT_SCHEMA="engine-failure"
    fi
    if [ "$MC_LINT_SCHEMA" = "engine-failure" ] || [ "$append" = "engine-failure" ]; then
        # An engine crash is never a finding -- unless the other check
        # already produced a real one, which is still worth saying.
        if [ "$MC_LINT_SCHEMA" != "fail" ] && [ "$append" != "fail" ]; then
            # A crash never clears a sticky finding: only a clean run does.
            RELINT="skipped:engine-failure"
            return 0
        fi
    fi
    if [ "$MC_LINT_SCHEMA" = "fail" ] && [ "$append" = "fail" ]; then
        kind="both"
    elif [ "$MC_LINT_SCHEMA" = "fail" ]; then
        kind="schema"
    elif [ "$append" = "fail" ]; then
        kind="append-only"
    fi
    if [ -z "$kind" ]; then
        RELINT="ok"
        if [ -f "$RELINT_MARKER" ]; then
            # The marker is keyed by project name only, so it records the
            # store root it came from; another store that shares the name
            # must neither clear nor be cleared by it. A marker without a
            # root line predates the field and is treated as this store's.
            mroot=""
            IFS= read -r mroot <"$RELINT_MARKER" 2>/dev/null || true
            case "$mroot" in
                root=*) mroot="${mroot#root=}" ;;
                *) mroot="$root_phys" ;;
            esac
            if [ "$mroot" = "$root_phys" ]; then
                rm -f "$RELINT_MARKER" 2>/dev/null
            else
                RELINT="ok marker=foreign"
            fi
        fi
        return 0
    fi
    RELINT="failed:$kind"
    # A marker another store (same project name, different root) left behind
    # is never overwritten: its finding stays visible. The banner still prints.
    local foreign=0
    if [ -f "$RELINT_MARKER" ]; then
        mroot=""
        IFS= read -r mroot <"$RELINT_MARKER" 2>/dev/null || true
        case "$mroot" in
            root=*) mroot="${mroot#root=}"; [ "$mroot" = "$root_phys" ] || foreign=1 ;;
        esac
    fi
    sha="$(git -C "$MEMCONTINUUM_ROOT" rev-parse HEAD 2>/dev/null)"
    short="$(git -C "$MEMCONTINUUM_ROOT" rev-parse --short HEAD 2>/dev/null)"
    {
        printf 'MemContinuum: commit %s in store %s skipped the commit checks and would have been refused:\n' "$short" "$PROJECT"
        [ "$MC_LINT_SCHEMA" = "fail" ] && printf '%s\n' "$MC_LINT_SCHEMA_OUT"
        [ "$append" = "fail" ] && printf '%s\n' "$append_out"
    } >&2
    summary="$( { [ "$MC_LINT_SCHEMA" = "fail" ] && printf '%s\n' "$MC_LINT_SCHEMA_OUT"
                  [ "$append" = "fail" ] && printf '%s\n' "$append_out"; } | grep '^memlint: ' | tr '\n' ';' )"
    if [ "$foreign" -eq 1 ]; then
        RELINT="failed:$kind marker=foreign"
        return 0
    fi
    # Write-then-rename: a full disk leaves the old marker, never an empty one.
    # The temp name is unique per process and created exclusively (noclobber),
    # so a planted symlink is never followed; the rename refuses a symlink or
    # directory marker path.
    local mtmp="$RELINT_MARKER.new.$$"
    rm -f "$mtmp" 2>/dev/null
    if (
        set -C
        {
            printf 'root=%s\n' "$root_phys"
            printf 'sha=%s\n' "$sha"
            printf 'date=%s\n' "$(date -Iseconds 2>/dev/null || date)"
            printf 'failed=%s\n' "$kind"
            printf 'summary=%s\n' "${summary%;}"
        } >"$mtmp"
    ) 2>/dev/null && mc_safe_replace "$mtmp" "$RELINT_MARKER"; then
        :
    else
        rm -f "$mtmp" 2>/dev/null
        RELINT="failed:$kind marker=write-failed"
    fi
    return 0
}
mc_post_commit_relint || RELINT="skipped:error"

# --- 4. store backup bundle ---------------------------------------------------
# Off unless MEMCONTINUUM_BACKUP_DIR is set (env, else config.sh). The dir
# must be absolute and already exist; only the per-store subfolder is
# created. Written as <name>.part.<pid> (unique per invocation), verified, then
# renamed over the final name (a bundle is a snapshot of the refs at commit
# time; two commits in one minute share a name and the later one wins).
# Any failure -> backup=failed:<reason>, the .part removed, exit code untouched.
BACKUP="off"
MC_PART_NOW=""
mc_backup_cleanup_part() {
    [ -n "$MC_PART_NOW" ] && rm -f "$MC_PART_NOW" 2>/dev/null
    return 0
}
mc_post_commit_backup() {
    local dir="${MEMCONTINUUM_BACKUP_DIR:-}" keep rawkeep="${MEMCONTINUUM_BACKUP_KEEP:-}" keep_bad=0
    local sub real_dir real_sub name part final head commits stat f
    local budget maxage age n others_count excess i swept=0 prune_failed=0 suffix=""
    [ -n "$dir" ] || { BACKUP="off"; return 0; }
    if [ "$MC_NO_WATCHDOG" -eq 1 ]; then BACKUP="skipped:no-watchdog"; return 0; fi
    # PROJECT and DIR were validated once, above, before any path was built.
    if [ "$BAD_PROJECT" -eq 1 ]; then BACKUP="skipped:bad-project"; return 0; fi
    if [ "$BAD_DIR" -eq 1 ]; then BACKUP="skipped:bad-dir"; return 0; fi
    if ! type mc_backup_keep_normalize >/dev/null 2>&1 \
            || ! type mc_backup_bundle_list >/dev/null 2>&1 \
            || ! type mc_backup_name_ok >/dev/null 2>&1 \
            || ! type mc_backup_part_ok >/dev/null 2>&1 \
            || ! type mc_physical >/dev/null 2>&1; then
        BACKUP="skipped:no-lib"; return 0
    fi
    if [ -z "$rawkeep" ]; then
        keep=10
    elif mc_backup_keep_normalize "$rawkeep"; then
        keep="$MC_BACKUP_KEEP_NORM"
    else
        keep=10; keep_bad=1
    fi
    if [ ! -d "$dir" ]; then BACKUP="skipped:dir-missing"; return 0; fi
    real_dir="$(mc_physical "$dir")"
    sub="$real_dir/$PROJECT"
    mkdir -p "$sub" 2>/dev/null || { BACKUP="failed:mkdir"; return 0; }
    # A symlinked <dir>/<project> pointing elsewhere is refused.
    real_sub="$(mc_physical "$sub")"
    case "$real_sub/" in
        "${real_dir%/}/"*) ;;
        *) BACKUP="failed:bad-project"; return 0 ;;
    esac
    sub="$real_sub"
    name="$PROJECT-$(date +%Y%m%d-%H%M 2>/dev/null).bundle"
    final="$sub/$name"
    part="$final.part.$$"
    # A watchdog SIGKILL skips every trap, so a killed run leaves its temp
    # behind. Sweep only grammar-checked leftovers (<name>.part.<digits>, the
    # old <name>.part, <name>.part.lock) whose mtime is older than twice the
    # watchdog budget: a younger one may belong to a live, overlapping hook.
    # Never by name order.
    budget="${MEMCONTINUUM_POST_COMMIT_BUDGET:-30}"
    case "$budget" in ''|*[!0-9]*) budget=30 ;; esac
    maxage=$((budget * 2))
    for f in "$sub/$PROJECT"-[0-9]*-[0-9]*.bundle.part "$sub/$PROJECT"-[0-9]*-[0-9]*.bundle.part.*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        mc_backup_part_ok "$PROJECT" "${f##*/}" || continue
        age="$("$PY" -c 'import os, sys, time
print(int(time.time() - os.lstat(sys.argv[1]).st_mtime))' "$f" 2>/dev/null)"
        case "$age" in ''|*[!0-9]*) continue ;; esac
        if [ "$age" -gt "$maxage" ]; then
            rm -f "$f" 2>/dev/null && swept=$((swept + 1))
        fi
    done
    [ "$swept" -gt 0 ] && suffix=" part-swept=$swept"
    MC_PART_NOW="$part"
    trap mc_backup_cleanup_part EXIT
    # The exclusive create IS the write: noclobber applies to the very
    # redirection git's stdout goes through, so no path is reopened and a
    # symlink swapped in is refused, not followed. The bundle goes to stdout
    # so git makes no .lock file.
    rm -f "$part" 2>/dev/null
    if ! ( set -C; git -C "$MEMCONTINUUM_ROOT" bundle create - --all >"$part" ) 2>/dev/null \
            || [ -L "$part" ]; then
        rm -f "$part" 2>/dev/null; BACKUP="failed:bundle-create$suffix"; return 0
    fi
    if ! git -C "$MEMCONTINUUM_ROOT" bundle verify "$part" >/dev/null 2>&1; then
        rm -f "$part" 2>/dev/null; BACKUP="failed:verify$suffix"; return 0
    fi
    stat="$("$PY" -c 'import hashlib, os, sys
p = sys.argv[1]
print(os.path.getsize(p), hashlib.sha256(open(p, "rb").read()).hexdigest())' "$part" 2>/dev/null)"
    case "$stat" in
        *" "*) ;;
        *) rm -f "$part" 2>/dev/null; BACKUP="failed:hash$suffix"; return 0 ;;
    esac
    if [ -L "$final" ] || [ -d "$final" ]; then
        rm -f "$part" 2>/dev/null; BACKUP="failed:dest$suffix"; return 0
    fi
    if ! mc_safe_replace "$part" "$final"; then
        rm -f "$part" 2>/dev/null; BACKUP="failed:rename$suffix"; return 0
    fi
    MC_PART_NOW=""
    head="$(git -C "$MEMCONTINUUM_ROOT" rev-parse HEAD 2>/dev/null)"
    commits="$(git -C "$MEMCONTINUUM_ROOT" rev-list --count HEAD 2>/dev/null)"
    # `>>` follows a symlink: never append through one (or into a directory).
    if [ -L "$sub/MANIFEST.txt" ] || { [ -e "$sub/MANIFEST.txt" ] && [ ! -f "$sub/MANIFEST.txt" ]; }; then
        BACKUP="ok-manifest-refused$suffix"
        return 0
    fi
    printf '%s | source=%s | HEAD=%s | commits=%s | bundle=%s | size=%s | sha256=%s\n' \
        "$PROJECT" "$MEMCONTINUUM_ROOT" "$head" "$commits" "$name" "${stat%% *}" "${stat#* }" \
        >>"$sub/MANIFEST.txt" 2>/dev/null || { BACKUP="failed:manifest$suffix"; return 0; }
    if [ "$keep_bad" -eq 1 ]; then
        # An unusable KEEP never prunes: the bundle just written stays.
        BACKUP="failed:bad-keep$suffix"
        return 0
    fi
    # Prune after a verified rename only: never the bundle just written (its
    # exact name is excluded, so a future-dated older name cannot displace
    # it); of the OTHERS keep at most keep-1, oldest names first removed.
    # MANIFEST lines are never pruned.
    mc_backup_bundle_list "$sub" "$PROJECT"
    n=${#MC_BACKUP_BUNDLES[@]}
    others_count=0
    i=0
    while [ "$i" -lt "$n" ]; do
        [ "${MC_BACKUP_BUNDLES[$i]}" != "$final" ] && others_count=$((others_count + 1))
        i=$((i + 1))
    done
    excess=$((others_count - (keep - 1)))
    if [ "$excess" -gt 0 ]; then
        i=0
        while [ "$i" -lt "$n" ] && [ "$excess" -gt 0 ]; do
            f="${MC_BACKUP_BUNDLES[$i]}"
            i=$((i + 1))
            [ "$f" != "$final" ] || continue
            excess=$((excess - 1))
            rm -f "$f" 2>/dev/null || prune_failed=1
            [ -e "$f" ] && prune_failed=1
        done
    fi
    if [ "$prune_failed" -eq 1 ]; then BACKUP="ok-prune-failed$suffix"; else BACKUP="ok$suffix"; fi
    return 0
}
mc_post_commit_backup || BACKUP="failed:error"

printf '%s post-commit-reindex: rc=%s elapsed=%ss project=%s root=%s embed=%s relint=%s backup=%s :: %s\n' \
    "$(date -Iseconds 2>/dev/null || date)" "$RC" "$ELAPSED" "$PROJECT" "$MEMCONTINUUM_ROOT" "$EMBED_STATE" "$RELINT" "$BACKUP" "$OUT" >>"$LOG" 2>/dev/null || true

# A commit should never be blocked by a reindex failure.
exit 0
