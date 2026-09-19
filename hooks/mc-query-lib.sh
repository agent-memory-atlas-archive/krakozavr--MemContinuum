#!/usr/bin/env bash
# mc-query-lib.sh -- pure, side-effect-free helpers that turn an edited
# FILE_PATH into a small bag of search words: the query the search-fallback
# channel (TOP-0133 L1) hands to `memidx.py search` when a pre-edit lookup
# (hooks/pre-edit-chain.sh) or a new-file nudge (hooks/newfile-nudge.sh)
# found nothing bound to the path. No I/O beyond argv/stdout, no MEMCONTINUUM_*
# defaulting, no git -- safe to source unconditionally, same discipline as
# hooks/mc-path-lib.sh (see that file's own header). bash-3.2-safe throughout
# (macOS CI): no `${var,,}`, no `mapfile`, no associative arrays -- `tr`/`sed
# -E`/a plain `for word in $unquoted` split instead.
#
# Two public functions:
#
#   mc_query_source_path PATH CWD STRIP_PREFIXES
#     Picks the form of PATH to tokenize -- a repo-relative path when one is
#     recoverable, the raw PATH otherwise. Tokenizing a raw absolute path
#     buries the filename's own words under machine-path noise ("home
#     someuser dev projectname ...", capped out by mc_query_tokens' own
#     12-token cap before the words that actually matter ever get a look),
#     and a worktree path's raw form spells its `.worktrees/x/...` segment
#     into the query too -- both are exactly the noise the query is
#     supposed to be built FROM THE PATH'S OWN WORDS, not from where it
#     happens to sit on disk. Tries, in order: CWD-relative (mirrors
#     pre-edit-chain.sh's own first candidate), then each colon-separated
#     STRIP_PREFIXES entry in turn (mirrors its MEMCONTINUUM_STRIP_PREFIX
#     candidates) -- the FIRST one that actually strips something wins;
#     falls back to PATH unchanged when none apply (STRIP_PREFIXES empty,
#     CWD empty/not a real ancestor, or PATH simply isn't under any of
#     them). Callers pass the WORKTREE-REMAPPED path here when one exists
#     (pre-edit-chain.sh's own WT_REMAPPED, already `<configured-root>/
#     <relative>` -- one of STRIP_PREFIXES strips it straight down to
#     <relative>), never the worktree's own raw path.
#
#   mc_query_tokens PATH
#     The query-builder proper. Prints the resulting tokens space-joined
#     on stdout (empty string, never an error, when nothing survives the
#     filters -- callers check for that themselves via `[ -z "$q" ]`, same
#     "print nothing" convention `mc_remap_worktree_path` etc. already use
#     for "not applicable"). Stated limits, in the order applied:
#       1. extension stripped from the FINAL path component only (a dot in
#          a directory name never truncates the path) -- `${base%.*}`.
#       2. split into words on `/ _ - .` (directories and the stem both)
#          AND on a camelCase boundary (a lowercase/digit letter directly
#          followed by an uppercase one).
#       3. lowercased.
#       4. any token shorter than 3 characters dropped.
#       5. any token in the fixed generic-stem list dropped (see
#          MC_QUERY_GENERIC_STEMS below) -- these name no project-specific
#          concept, they just describe "this is code".
#       6. deduped, first occurrence wins (path order preserved).
#       7. capped at 12 tokens.
#     No relevance floor, no ranking here -- this only decides WHICH words
#     reach the search call at all; how those words rank once they get
#     there is memidx.py search's own job (deliberately unchanged by this
#     feature -- see docs/DESIGN.md's search-fallback ruling for why).

# MC_QUERY_GENERIC_STEMS -- exact list per TOP-0133 L1's own spec: words that
# describe "this is code" rather than naming a project-specific concept.
# Space-separated (matches the split-word loop's own `for word in $list`
# idiom used throughout hooks/*.sh -- see hooks/newfile-nudge.sh's
# _ext_matches for the same unquoted-on-purpose pattern), checked via a
# padded `case " $list " in *" $word "*)` substring test so no per-word
# array/loop is needed to answer "is $word in this list".
MC_QUERY_GENERIC_STEMS="src lib sources source docs doc test tests spec main index utils util helpers internal app core common base"

# mc_query_source_path PATH CWD STRIP_PREFIXES
mc_query_source_path() {
    local path="$1" cwd="$2" prefixes="$3" prefix stripped
    if [ -n "$cwd" ]; then
        stripped="${path#"$cwd"/}"
        if [ "$stripped" != "$path" ]; then
            printf '%s' "$stripped"
            return 0
        fi
    fi
    if [ -n "$prefixes" ]; then
        local _mc_qsp_prefix
        local IFS=':'
        for _mc_qsp_prefix in $prefixes; do
            [ -z "$_mc_qsp_prefix" ] && continue
            stripped="${path#"$_mc_qsp_prefix"}"
            if [ "$stripped" != "$path" ]; then
                # STRIP_PREFIX entries are rendered WITHOUT a trailing
                # slash's guarantee either way (pre-edit-chain.sh's own
                # candidate builder makes no such assumption -- see its
                # `add_candidate "${FILE_PATH#"$prefix"}"` above); a bare
                # leading slash left behind by the strip is trimmed so the
                # relative form never starts with one.
                stripped="${stripped#/}"
                printf '%s' "$stripped"
                return 0
            fi
        done
    fi
    printf '%s' "$path"
}

# mc_query_tokens PATH -- see file header for the full, numbered rule.
mc_query_tokens() {
    local path="$1" dir base words lower word out="" count=0
    base="${path##*/}"
    dir="${path%/*}"
    [ "$dir" = "$path" ] && dir=""
    case "$base" in
        *.*) base="${base%.*}" ;;
    esac
    if [ -n "$dir" ]; then
        path="$dir/$base"
    else
        path="$base"
    fi
    # Split on / _ - . (rule 2, path half) via `tr`; the camelCase half of
    # rule 2 (`sed -E`) runs on the ALREADY-space-split text next -- doing
    # both in one `tr` pass is not possible (tr has no lookaround), and
    # running sed first (before the path separators are gone) would let
    # `-E`'s own `.` metacharacter make the camelCase pattern match across
    # a `/`, which it must never do.
    words="$(printf '%s' "$path" | tr '/_.-' '    ')"
    words="$(printf '%s' "$words" | sed -E 's/([a-z0-9])([A-Z])/\1 \2/g')"
    lower="$(printf '%s' "$words" | tr '[:upper:]' '[:lower:]')"
    for word in $lower; do
        [ ${#word} -lt 3 ] && continue
        case " $MC_QUERY_GENERIC_STEMS " in *" $word "*) continue ;; esac
        case " $out " in *" $word "*) continue ;; esac
        out="${out:+$out }$word"
        count=$((count + 1))
        [ "$count" -ge 12 ] && break
    done
    printf '%s' "$out"
}
