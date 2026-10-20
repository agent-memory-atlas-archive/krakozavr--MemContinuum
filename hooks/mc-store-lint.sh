# hooks/mc-store-lint.sh -- the store's two commit-time lint checks, in ONE
# place. SOURCED (never executed) by hooks/pre-commit-append-only.sh, which
# refuses a commit on a finding, and by hooks/post-commit-reindex.sh, which
# re-runs the same checks after the commit to catch `git commit --no-verify`
# (it skips pre-commit, never post-commit). Both hooks must judge a record by
# exactly the same rules, so the memlint invocations and the verdict parsing
# live here and nowhere else.
#
# bash 3.2 safe. Defines functions only; never exits, never writes to the
# terminal or to hook.log -- each function sets result variables and returns
# 0, and the caller decides what a finding means (block, or warn).
#
# mc_store_lint_schema PY MEMLINT ROOT
#   Plain schema pass (`memlint.py ROOT`, no --against-ref, no --code-root;
#   INC-0127). Sets:
#     MC_LINT_SCHEMA      ok | fail | engine-failure
#     MC_LINT_SCHEMA_OUT  memlint's combined output
#     MC_LINT_SCHEMA_SUMMARY  1 when memlint printed its own summary line
#                         (`memlint: clean` / `memlint: N error(s)`), else 0.
#                         Pre-commit ignores it (it fails open); post-commit
#                         treats an `ok` WITHOUT a summary as engine-failure,
#                         so a stub interpreter can never clear a sticky marker.
#   Python exits 1 on ANY uncaught exception, so RC=1 counts as a finding
#   only together with memlint's own `memlint: N error(s)` summary marker; a
#   1 without it (a venv that cannot import memlint's dependencies) or any
#   other non-zero RC is engine-failure, never a finding.
#
# mc_store_lint_append_only PY MEMLINT ROOT REF
#   Append-only diff of the INDEX against REF (`memlint.py --against-ref REF
#   --staged ROOT`): HEAD for pre-commit (index = what is about to be
#   committed), HEAD~1 for post-commit (after a commit the index equals HEAD
#   for the committed paths, so this is HEAD-vs-HEAD~1). Sets:
#     MC_LINT_APPEND      ok | fail | engine-failure
#     MC_LINT_APPEND_OUT  memlint's combined output
#     MC_LINT_APPEND_RC   memlint's exit code
#     MC_LINT_CHANGED     the `changed=N` count ("" when the marker is absent)
#     MC_LINT_NOTES       the `notes=N` count ("?" when absent)
#   RC is trusted as a verdict only together with the `changed=` marker; no
#   marker (a crash, RC=2 from git/ref resolution) is engine-failure.

mc_store_lint_schema() {
    local py="$1" memlint="$2" root="$3" rc
    MC_LINT_SCHEMA_OUT="$(PYTHONPATH= "$py" "$memlint" "$root" 2>&1)"
    rc=$?
    MC_LINT_SCHEMA="ok"
    MC_LINT_SCHEMA_SUMMARY=0
    case "$MC_LINT_SCHEMA_OUT" in
        *"memlint: clean"*|*"memlint: "*" error(s)"*) MC_LINT_SCHEMA_SUMMARY=1 ;;
    esac
    if [ "$rc" -eq 1 ]; then
        case "$MC_LINT_SCHEMA_OUT" in
            *"memlint: "*" error(s)"*) MC_LINT_SCHEMA="fail" ;;
            *) MC_LINT_SCHEMA="engine-failure" ;;
        esac
    elif [ "$rc" -ne 0 ]; then
        MC_LINT_SCHEMA="engine-failure"
    fi
    return 0
}

mc_store_lint_append_only() {
    local py="$1" memlint="$2" root="$3" ref="$4" tail
    MC_LINT_APPEND_OUT="$(PYTHONPATH= "$py" "$memlint" --against-ref "$ref" --staged "$root" 2>&1)"
    MC_LINT_APPEND_RC=$?
    MC_LINT_CHANGED=""
    case "$MC_LINT_APPEND_OUT" in
        *"changed="*)
            tail="${MC_LINT_APPEND_OUT##*changed=}"
            MC_LINT_CHANGED="${tail%% *}"
            ;;
    esac
    case "$MC_LINT_CHANGED" in
        ''|*[!0-9]*) MC_LINT_CHANGED="" ;;
    esac
    # notes=N: memlint's count of structural-extraction bail-outs; always
    # surfaced so a NOTE never reaches nobody just because rc=0.
    MC_LINT_NOTES=""
    case "$MC_LINT_APPEND_OUT" in
        *"notes="*)
            tail="${MC_LINT_APPEND_OUT##*notes=}"
            MC_LINT_NOTES="${tail%% *}"
            ;;
    esac
    case "$MC_LINT_NOTES" in
        ''|*[!0-9]*) MC_LINT_NOTES="?" ;;
    esac
    MC_LINT_APPEND="engine-failure"
    if [ -n "$MC_LINT_CHANGED" ]; then
        if [ "$MC_LINT_APPEND_RC" -eq 0 ]; then
            MC_LINT_APPEND="ok"
        elif [ "$MC_LINT_APPEND_RC" -eq 1 ]; then
            MC_LINT_APPEND="fail"
        fi
    fi
    return 0
}
