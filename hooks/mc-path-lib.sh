#!/usr/bin/env bash
# mc-path-lib.sh -- one pure, side-effect-free function: mc_path_under_root.
# Source this file (not hooks/memlib.sh) when that is all a caller needs --
# unlike memlib.sh, sourcing this file does no I/O, sets no MEMCONTINUUM_*
# defaults, and touches no filesystem beyond what mc_path_under_root itself
# does when actually CALLED. Safe to source unconditionally at the top of a
# script, or lazily right before first use, with identical cost either way.
#
# Sourced by hooks/memlib.sh (so every one of its callers gets
# mc_path_under_root for free) and directly by hooks/newfile-nudge.sh (which
# needs mc_path_under_root but deliberately does NOT source memlib.sh -- see
# that file's own header for why). One implementation, two independent
# callers, extracted here specifically so newfile-nudge.sh never has to pay
# memlib.sh's mkdir/config.sh/MC_PY-resolution cost just to reach this one
# function (symlink-paths review round 1, finding 3).

# mc_path_under_root FILE_PATH ROOT
#
# Symlink-safe containment: does FILE_PATH's real location sit under ROOT's
# real location? Originally hooks/newfile-nudge.sh's own fix (2026-08-31
# review) for its PreToolUse containment check; factored out (first into
# hooks/memlib.sh, then here) so hooks/ledger-post-edit.sh shares the SAME
# implementation instead of keeping the plain lexical prefix match that fix
# already replaced in newfile-nudge.sh -- one implementation, both hooks
# call it.
#
# A plain lexical `case "$FILE_PATH" in "$ROOT"/*` prefix match is fooled
# both by a literal `/../` traversal segment (textually under ROOT while
# actually resolving to a sibling of it) and by a symlinked ancestor
# directory (every path segment textually under ROOT, but the real
# directory it names lives elsewhere). Fixed bash-3.2-safe, no external
# binaries beyond what every caller here already uses:
#   1. reject any literal `/../` traversal segment (or a leading `../`, or
#      a bare `..`) outright, purely as a string -- a syntactic red flag
#      regardless of what it would resolve to.
#   2. canonicalize ROOT and the nearest EXISTING ancestor directory of
#      FILE_PATH (walking up via dirname -- handles both a FILE_PATH that
#      already exists, ledger-post-edit.sh's usual case, and one that does
#      not yet, newfile-nudge.sh's usual case) via `cd ... && pwd -P`,
#      which resolves symlinks, and require that ancestor to sit under the
#      canonicalized root -- compared as a LITERAL string (see below), not
#      as a case/glob pattern.
#
# Returns WHY, not just yes/no -- newfile-nudge.sh's outcome= vocabulary
# distinguishes these in hook.log (memidx.py stats greps it); a caller
# that only needs yes/no (ledger-post-edit.sh) collapses every nonzero
# into its own single out-of-scope outcome.
#   0  under ROOT
#   1  outside ROOT (both resolve, but FILE_PATH's ancestor is not under it)
#   2  literal `..` traversal segment in FILE_PATH
#   3  ROOT itself does not resolve (missing, not a directory, etc.)
#   4  FILE_PATH has no existing ancestor to resolve from
#   5  FILE_PATH's existing ancestor does not resolve
mc_path_under_root() {
    local file_path="$1" root="$2" root_real ancestor next ancestor_real stripped
    case "$file_path" in
        */../*|*/..|../*|..) return 2 ;;
    esac
    root_real="$(cd "$root" 2>/dev/null && pwd -P)"
    [ -n "$root_real" ] || return 3
    ancestor="$file_path"
    while [ ! -d "$ancestor" ]; do
        next="$(dirname "$ancestor")"
        if [ "$next" = "$ancestor" ]; then
            return 4
        fi
        ancestor="$next"
    done
    ancestor_real="$(cd "$ancestor" 2>/dev/null && pwd -P)"
    [ -n "$ancestor_real" ] || return 5
    if [ "$ancestor_real" = "$root_real" ]; then
        return 0
    fi
    # Segment-aware, LITERAL prefix test -- never a case/glob pattern match
    # on $root_real (symlink-review round 1, finding 1): a store/code root
    # whose physical directory name happens to contain a shell glob
    # metacharacter (*, ?, [) must still be compared as a literal string,
    # never interpreted as a wildcard. `${var#"$prefix"}` with the prefix
    # itself double-quoted performs LITERAL removal (bash's quote-removal
    # applies to the quoted portion of a parameter-expansion pattern before
    # any globbing would apply to it) -- so `stripped` differs from
    # `ancestor_real` iff `ancestor_real` truly began with the literal
    # `"$root_real/"` string. `/foo` can never match a `/foobar` ancestor
    # this way (segment-aware), and a literal `*`/`?`/`[` inside
    # `$root_real` can never accidentally widen the match (glob-safe).
    # Verified directly under both bash 5.2 and the real bash 3.2.57.
    stripped="${ancestor_real#"$root_real"/}"
    if [ "$stripped" != "$ancestor_real" ]; then
        return 0
    fi
    return 1
}

# mc_remap_worktree_path FILE_PATH ROOTS
#
# The worktree gap (docs/internal/SESSION-HANDOFF-releases-0.3-to-0.6.md
# SS"0.2.0 final" item 1): MEMCONTINUUM_CODE_ROOTS/MEMCONTINUUM_STRIP_PREFIX name
# absolute paths fixed at repo-init time. A `git worktree add` checkout of
# a wired repo is a different absolute directory nothing wired -- every
# candidate hooks/pre-edit-chain.sh builds and hooks/ledger-post-edit.sh's
# own root-containment loop both come up empty, indistinguishable from a
# genuine absence. This function maps the EDITED PATH back to its
# main-checkout equivalent so the existing candidate/containment logic can
# be reused unchanged -- it does not itself decide anything about whether a
# decision applies, and it never causes worktree CONTENT to be indexed
# (only a path string is computed here).
#
# ROOTS is a newline-separated list of configured code-root absolute paths
# (mc_code_roots' own output shape for ledger-post-edit.sh; the caller
# builds it from MEMCONTINUUM_STRIP_PREFIX -- stripped of a trailing slash --
# for pre-edit-chain.sh, which deliberately does not source memlib.sh/
# mc_code_roots to avoid that file's mkdir/config.sh cost on every
# already-a-miss lookup; repo-init.sh renders exactly one STRIP_PREFIX
# entry, = the one code root that invocation is scoped to, per
# CODE_ROOT_FILTERS in templates/code-root-filter-pair.json.tmpl -- a
# hand-wired STRIP_PREFIX that happens not to equal any real repo root
# only ever makes ROOT_GIT_REAL fail to resolve below, i.e. the remap
# silently doesn't fire; it can never produce a FALSE match, since the
# match test is exact directory-identity, never a prefix/substring test.
#
# Caller contract (both hooks): call this ONLY after every existing
# candidate/containment check has already failed for FILE_PATH itself --
# see each hook's own comment at its call site for why. A file already
# inside a configured root never reaches here, so the common case pays no
# extra `git` call at all. Also gate on `mc_path_under_root FILE_PATH ROOT`
# for each ROOT first (pre-edit-chain.sh does this explicitly since it has
# no other containment check of its own) -- a file that's already IN a
# configured root but genuinely has no decision bound to it must stay a
# plain no-match, never pay for or receive a worktree remap attempt.
#
# Detection, in order (cheapest guard first, one `git` process at most):
#   1. FILE_PATH must be absolute and free of a literal `..` traversal
#      segment (same syntactic guard as mc_path_under_root) -- anything
#      else: not applicable, return 3, no git call.
#   2. Walk FILE_PATH up to its nearest EXISTING ancestor directory (same
#      walk as mc_path_under_root -- covers a Write of a file that does not
#      exist yet), then walk THAT up to `/` doing a bare `[ -e "$d/.git" ]`
#      check (no subprocess -- same "rule out no .git entry at all"
#      precedent hooks/ledger-post-edit.sh's own shell-diff branch already
#      uses for exactly this reason). No `.git` anywhere on the chain: this
#      ancestor is not in any git checkout at all -- not applicable, return
#      3, no git call. This is what keeps an ordinary /tmp or /mnt file (by
#      far the common shape of a genuine miss) from ever spawning git.
#   3. A `.git` entry exists somewhere above: exactly ONE `git -C <ancestor>
#      rev-parse --git-common-dir --show-toplevel` call. Either line
#      missing, or either resolves-to-absolute step below fails: git itself
#      could not settle the question -- return 2 (worktree-unresolved; the
#      caller logs a NAMED outcome instead of a silent no-match/out-of-
#      scope, per the "say something when it cannot resolve" floor -- this
#      also covers a repo whose `.git` was created via `--separate-git-dir`
#      pointing somewhere this resolution can't follow, deliberately: out
#      of scope, treated the same as "can't tell").
#   4. --git-common-dir and --show-toplevel are each resolved to an
#      absolute, symlink-safe path via `cd ... && pwd -P` (the same
#      resolution mc_path_under_root already uses for ROOT/ancestor above;
#      --git-common-dir can print a RELATIVE path -- relative to the `-C`
#      directory -- on git versions this repo doesn't pin a floor above,
#      hence the two-step `cd ancestor && cd common_raw`).
#   5. Resolved common-dir == resolved-toplevel + "/.git" (a plain STRING
#      comparison, not a second `cd` into it -- a linked worktree's own
#      `.git` is a FILE, not a directory, so relying on a `cd` failing
#      there would be an accident of the worktree case, not a real check):
#      this ancestor is an ORDINARY checkout, not a linked worktree at all
#      (editing a file that happens to live under some other, unconfigured
#      repo's own main checkout) -- not applicable, return 3. This is what
#      keeps the common "genuinely outside every configured root, and not
#      a worktree either" miss from ever being renamed away from its
#      today's plain outcome.
#   6. Otherwise this genuinely IS a linked worktree. Compute FILE_PATH's
#      physical location (ancestor_real + whatever of FILE_PATH sat past
#      the ancestor, same reconstruction mc_path_under_root's callers rely
#      on for a not-yet-existing file) and its path relative to the
#      worktree's own toplevel -- code_refs are written relative to a
#      checkout root and a worktree mirrors its main checkout's tracked
#      layout exactly, so that relative form is exactly what a main-
#      checkout edit of the same file would also be relative to.
#   7. For each ROOT: resolve "$ROOT/.git" the same `cd && pwd -P` way and
#      compare it to the resolved common-dir by exact string identity
#      (never a prefix/glob test -- see the STRIP_PREFIX note above for why
#      this can only fail closed). First match: print
#      "$ROOT/$relative" and return 0. No ROOT matches at all: this
#      worktree's main repo was never wired as a code root here -- return 1
#      (worktree-unwired) -- the correctness condition the caller must not
#      skip (docs/internal handoff item 1): remapping onto an UNWIRED
#      repo's records would be a false hit against a decision that has
#      nothing to do with it.
#
# Returns (never writes anything on any nonzero return):
#   0  remapped -- stdout carries the one-line main-checkout-equivalent
#      absolute path
#   1  worktree-unwired  -- confirmed a linked worktree; no ROOT matched
#   2  worktree-unresolved -- confirmed (or suspected, via a `.git` entry)
#      to be repo-related but git itself failed or a resolution step did
#   3  not applicable -- FILE_PATH is malformed/relative, no `.git` entry
#      exists on its ancestor chain at all, or this ancestor is an
#      ordinary (non-worktree) checkout -- caller's existing outcome is
#      unchanged, nothing new to log
mc_remap_worktree_path() {
    local file_path="$1" roots="$2"
    local ancestor next probe found_git
    local cd_out common_raw toplevel_raw common_real toplevel_real
    local ancestor_real tail physical_file_path relative
    local root root_slash root_git_real remapped

    case "$file_path" in
        /*) ;;
        *) return 3 ;;
    esac
    case "$file_path" in
        */../*|*/..|../*|..) return 3 ;;
    esac

    ancestor="$file_path"
    while [ ! -d "$ancestor" ]; do
        next="$(dirname "$ancestor")"
        if [ "$next" = "$ancestor" ]; then
            return 3
        fi
        ancestor="$next"
    done

    found_git=0
    probe="$ancestor"
    while :; do
        if [ -e "$probe/.git" ]; then
            found_git=1
            break
        fi
        [ "$probe" = "/" ] && break
        probe="$(dirname "$probe")"
    done
    [ "$found_git" -eq 1 ] || return 3

    cd_out="$(git -C "$ancestor" rev-parse --git-common-dir --show-toplevel 2>/dev/null)"
    [ -n "$cd_out" ] || return 2
    common_raw=""
    toplevel_raw=""
    {
        IFS= read -r common_raw
        IFS= read -r toplevel_raw
    } <<EOF
$cd_out
EOF
    [ -n "$common_raw" ] && [ -n "$toplevel_raw" ] || return 2

    toplevel_real="$(cd "$toplevel_raw" 2>/dev/null && pwd -P)"
    [ -n "$toplevel_real" ] || return 2
    common_real="$(cd "$ancestor" 2>/dev/null && cd "$common_raw" 2>/dev/null && pwd -P)"
    [ -n "$common_real" ] || return 2

    if [ "$common_real" = "$toplevel_real/.git" ]; then
        return 3
    fi

    ancestor_real="$(cd "$ancestor" 2>/dev/null && pwd -P)"
    [ -n "$ancestor_real" ] || return 2
    tail="${file_path#"$ancestor"}"
    physical_file_path="${ancestor_real}${tail}"

    relative="${physical_file_path#"$toplevel_real"/}"
    if [ "$relative" = "$physical_file_path" ]; then
        return 2
    fi

    while IFS= read -r root; do
        [ -n "$root" ] || continue
        root_slash="${root%/}"
        root_git_real="$(cd "$root_slash/.git" 2>/dev/null && pwd -P)"
        [ -n "$root_git_real" ] || continue
        if [ "$root_git_real" = "$common_real" ]; then
            remapped="${root_slash}/${relative}"
            printf '%s\n' "$remapped"
            return 0
        fi
    done <<EOF
$roots
EOF

    return 1
}
