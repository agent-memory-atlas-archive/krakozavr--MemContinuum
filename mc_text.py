"""mc_text.py -- the content-term vocabulary shared by memidx.py's own
INC-0115 query/document-coverage scoring and hooks/memlib.sh's prompt-derived
query terms (TOP-0133 L2). Split out of memidx.py so a hook's own one-liner
(`sys.path.insert(0, <engine root>); import mc_text`) never has to import the
whole ~9,000-line memidx module (yaml, chunkers, sqlite3, ...) just to
tokenize a handful of words. memidx.py itself imports these three names from
here (`from mc_text import _STOPWORDS, _CONTENT_TOKEN_RE, _content_terms`)
rather than defining them twice -- every existing caller and test in
memidx.py keeps referencing `memidx._STOPWORDS`/`memidx._CONTENT_TOKEN_RE`/
`memidx._content_terms` unchanged (they are the SAME objects, re-exported,
not copies -- `memidx._content_terms is mc_text._content_terms`).

No third-party imports here on purpose (only `re`, stdlib) -- this module
must stay importable with no PYTHONPATH beyond its own directory and no
virtualenv at all, since hooks/memlib.sh's `_prompt_terms` field runs under
the SAME bare `env PYTHONPATH=` invocation every other one-liner in that file
uses.
"""
from __future__ import annotations

import re

_STOPWORDS = frozenset("""
a an the is are was were be been being do does did doing have has had having
i you he she it we they me him her us them my your his its our their this
that these those to of in on at by for with about against between into
through during before after above below from up down out off over under
again further then once here there when where why how all any both each
few more most other some such no nor not only own same so than too very
can will just don should now what which who whom or and but if because as
until while
""".split())
_CONTENT_TOKEN_RE = re.compile(r"[a-z0-9]+")

# _PROMPT_FILLER (TOP-0133 L2, fix round 1 -- Grok's judgement, adopted by
# the orchestrator; reversible): conversational filler, applied ONLY by
# hooks/memlib.sh's `_prompt_terms` derivation -- NEVER by `_content_terms`
# below, which memidx's own coverage scoring uses and which must stay
# byte-identical. On an owner-shaped prompt like "please explain me the
# level of importance", `_content_terms`'s own stopword list alone leaves
# `please explain level importance` -- four terms, enough to open the
# search gate -- and `memidx.fts_escape` ORs every term together, so one
# leftover word (`please`, `explain`, ...) that happens to occur anywhere
# in the store is a hit on its own; collecting OR-hits on boilerplate like
# that mostly measures the tokenizer, which is exactly what the ruling's
# "weeks of measurement" are meant to decide instead. This list is the
# accepted, TUNABLE filter for that -- a term-side filter only, no effect
# on FTS ranking or on what a document itself contains -- deliberately
# free of domain words (`review`, `fix`, `search`, `hook`, `test`, ...
# stay searchable). Fix round 2 (TOP-0133 L2, Grok NIT): `look` dropped
# from this list -- this store's own "look-back" (the feature name)
# tokenizes to `look` + `back`, and `look` is the distinctive half; a
# prompt asking about it (e.g. "please explain the look-back reminder
# design") must keep `look` as a searchable term. Fix round 3 (TOP-0133
# L2, Codex final26 review): `still` dropped too, same reasoning -- it
# occurs across 15 of this store's own topic files, carrying real
# currentness/supersession intent ("is TOP-xxxx still the ruling",
# "does this still apply"), not pure filler; keeping it out of this list
# lets a short, otherwise-borderline prompt that hinges on that one word
# still clear the four-term gate and still be searchable.
_PROMPT_FILLER = frozenset("""
please explain want need help tell show thanks thank let lets like think
know see make sure just also really actually maybe something anything
everything nothing thing things way well okay yes yeah right hmm
""".split())

# _MACHINE_PROMPT_PREFIXES (TOP-0133 L3): Claude Code delivers machine text
# -- subagent hand-back reports and background-task notifications -- through
# the SAME UserPromptSubmit event a typed prompt arrives on; the payload
# carries no field that distinguishes the two (reading transcript_path is
# forbidden, ruling B). Both shapes are framed with a fixed prefix, verified
# from a live session's hook.log `q=` terms (`agent+message+...+subagent
# +hand+back...`, `task+notification+...+tool+use+toolu...`) and the raw
# prompt text behind them: a task notification's first non-whitespace
# characters are `<task-notification>`; a subagent hand-back / peer message
# opens with `Another Claude session sent a message:` followed by
# `<agent-message from="...">`; a cross-session message opens with
# `<cross-session-message from="...">`. hooks/memlib.sh's `_prompt_terms`
# branch -- the ONE process that reads the prompt -- checks
# `text.lstrip().startswith(_MACHINE_PROMPT_PREFIXES)` (a PREFIX match, not a
# substring one, so a human prompt that merely mentions "task-notification"
# or "agent-message" mid-sentence still searches) before tokenizing anything,
# and reports the classification via a second output field, PROMPT_SOURCE
# ("human" / "machine" / empty when there is no prompt string at all) --
# never a second process, never a second payload read. This list is a
# STATED LIMIT, not a guarantee: if Claude Code ever rewords its own
# framing, the skip silently stops matching -- visible in hook.log as
# `reason=non-user` falling to zero while machine-looking terms (hex ids,
# `toolu`) reappear in `q=` (see docs/INTERNALS.md).
_MACHINE_PROMPT_PREFIXES = (
    "<task-notification>",
    "<cross-session-message",
    "<agent-message",
    "Another Claude session sent a message:",
)


def _content_terms(text: str) -> set[str]:
    """INC-0115: non-stopword, length>1 tokens -- the same definition
    tests/test_bench.py's paraphrase-independence check uses to verify a
    paraphrase query shares no vocabulary with its target, now reused (not
    duplicated) here to decide, at query time, whether the FTS channel's
    own top hit actually shares any.

    STATED LIMIT (not fixed here -- the owner wants real query data before
    touching tokenization): `_CONTENT_TOKEN_RE` (`[a-z0-9]+`) drops every
    1-character and non-ASCII token, on both the query side and the
    document side. FTS5's own tokenizer keeps 1-character tokens (a bare
    digit, a single letter used as an identifier), so a query anchored on
    one -- "the 6 attempts limit", "an x coordinate" -- never puts that
    anchor into `qtok` at all, even when FTS5 itself matched on it and the
    document contains it verbatim. Coverage is computed only over the
    tokens this function keeps; a short, anchor-heavy query can therefore
    read a lower coverage than FTS5's own match actually earned it."""
    return {w for w in _CONTENT_TOKEN_RE.findall(text.lower()) if w not in _STOPWORDS and len(w) > 1}
