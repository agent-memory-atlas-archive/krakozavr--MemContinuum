"""Cited-commit / file:line verification (docs/SCHEMA.md sec3/sec9 addendum;
INC-0124's "cited commits" pull-forward, TOP-0129 L1's mutation-testing
doctrine). Mirrors tests/test_memlint.py's own style: a throwaway
tempdir store per test, memlint.lint_root/lint_topic/lint_record called
directly rather than through main() where a return value is asserted."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

TOOLS_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOLS_DIR))

import memlint  # noqa: E402


def _run_git(args, cwd):
    subprocess.run(["git"] + args, cwd=str(cwd), check=True, capture_output=True)


def make_fixture_repo(root: Path) -> tuple[str, str, str, str]:
    """A tiny git repo under `root` with two commits. Returns
    (first_hash, first_subject, second_hash, second_subject)."""
    _run_git(["init", "-q"], root)
    _run_git(["config", "user.email", "fixture@example.com"], root)
    _run_git(["config", "user.name", "Fixture"], root)
    (root / "a.py").write_text("def f():\n    return 1\n")
    _run_git(["add", "a.py"], root)
    _run_git(["commit", "-q", "-m", "Add a.py with f()"], root)
    first = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=str(root), capture_output=True, text=True, check=True
    ).stdout.strip()
    (root / "a.py").write_text("def f():\n    return 2\n")
    _run_git(["add", "a.py"], root)
    _run_git(["commit", "-q", "-m", "Change f() to return 2"], root)
    second = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=str(root), capture_output=True, text=True, check=True
    ).stdout.strip()
    return first[:7], "Add a.py with f()", second[:7], "Change f() to return 2"


def topic_md(cid: str, source: str = "", evidence: list | None = None) -> str:
    evidence = evidence if evidence is not None else []
    ev_yaml = "[" + ", ".join(repr(e) for e in evidence) + "]"
    return (
        "---\n"
        "type: topic\n"
        f"id: {cid}\n"
        "title: Citation fixture\n"
        "area: memory\n"
        "current: L1\n"
        "links:\n"
        "  - link: L1\n"
        "    date: 2026-09-19\n"
        "    status: active\n"
        "    kind: adopted\n"
        "    ruling:\n"
        "      text: \"a ruling\"\n"
        "      authority: agent-inference\n"
        f"      source: {source!r}\n"
        f"    evidence: {ev_yaml}\n"
        "    recorded_by: fable\n"
        "    recorded_at: 2026-09-19\n"
        "---\n\nFixture.\n"
    )


def incident_md(iid: str, source: str = "", evidence: list | None = None) -> str:
    evidence = evidence if evidence is not None else []
    ev_lines = "\n".join(f"  - {e!r}" for e in evidence)
    return (
        "---\n"
        "type: incident\n"
        f"id: {iid}\n"
        "title: Citation fixture incident\n"
        "area: memory\n"
        "status: active\n"
        "authority: agent-inference\n"
        f"source: {source!r}\n"
        f"evidence:\n{ev_lines}\n"
        "---\n\nFixture.\n"
    )


class TestCommitCitationRecognizer(unittest.TestCase):
    """The recognizer itself, no git involved -- acceptance-6-style
    precision cases (real store hex strings that must NOT be read as
    commits)."""

    def test_context_word_variants_all_recognized(self):
        for text, expect in [
            ("commit abc1234 landed", "abc1234"),
            ("merge abc1234 into main", "abc1234"),
            ("gate on PR #18 at f7fe011, 2026-09-14", "f7fe011"),
            ("merged as 87663ec", "87663ec"),
        ]:
            cites = memlint._extract_commit_citations(text)
            self.assertEqual([c["hash"] for c in cites], [expect], text)

    def test_backtick_wrapped_short_and_full_hash_recognized(self):
        self.assertEqual(
            [c["hash"] for c in memlint._extract_commit_citations("`abc1234`")], ["abc1234"]
        )
        full = "a" * 40
        self.assertEqual(
            [c["hash"] for c in memlint._extract_commit_citations(f"`{full}`")], [full]
        )

    def test_bare_backticked_16_hex_token_is_never_a_commit(self):
        self.assertEqual(memlint._extract_commit_citations("`781049f1321a1382`"), [])

    def test_12_hex_render_fingerprint_after_at_is_excluded(self):
        text = "rendered by 118974ef7600 against an engine at 049884e8b2ed"
        self.assertEqual(memlint._extract_commit_citations(text), [])

    def test_bare_hash_with_no_trigger_word_is_invisible(self):
        self.assertEqual(memlint._extract_commit_citations("fixed by e21bfa0 the same day"), [])

    def test_against_is_not_a_trigger_word(self):
        self.assertEqual(
            memlint._extract_commit_citations("append-only against f2d3f80~1: changed=2"), []
        )

    def test_quoted_subject_immediately_after_hash_is_captured(self):
        cites = memlint._extract_commit_citations('commit abc1234 "Add a.py with f()"')
        self.assertEqual(cites, [{"hash": "abc1234", "subject": "Add a.py with f()"}])

    def test_no_quote_means_no_subject_claim(self):
        cites = memlint._extract_commit_citations("commit abc1234 (16:03) added links")
        self.assertEqual(cites, [{"hash": "abc1234", "subject": None}])

    def test_owner_quote_after_an_at_triggered_hash_is_not_a_subject_claim(self):
        """Fix round (Opus MINOR): a quote directly after an at/as-triggered
        hash used to be misread as a claimed commit subject -- this store's
        owner-verbatim convention often puts a quote of the OWNER'S words
        shortly after ANY kind of reference, unrelated to a commit. Only
        commit/merge-triggered hashes are subject-eligible now."""
        text = (
            'Owner, 2026-09-14, gate at af95af2 '
            '"Codex is back, use it rather than Opus"'
        )
        cites = memlint._extract_commit_citations(text)
        self.assertEqual(cites, [{"hash": "af95af2", "subject": None}])

    def test_backtick_wrapped_hash_followed_by_a_quote_is_not_a_subject_claim(self):
        cites = memlint._extract_commit_citations('`abc1234` "unrelated quoted text"')
        self.assertEqual(cites, [{"hash": "abc1234", "subject": None}])

    def test_quote_on_a_later_line_is_not_a_subject_claim(self):
        """A commit/merge-triggered hash whose "nearest" quote sits on a
        LATER line (a YAML `|` block scalar preserves real newlines) must
        never bind to it -- same-line only."""
        text = 'commit abc1234 landed here.\nA later paragraph says "unrelated quote".'
        cites = memlint._extract_commit_citations(text)
        self.assertEqual(cites, [{"hash": "abc1234", "subject": None}])

    def test_8_hex_backtick_token_is_never_a_commit(self):
        """This store carries `e28e83a8` (8-hex) three times; none are
        commits. A length-widened recognizer ({7,8} instead of exactly 7 or
        40) would wrongly start reading them as short hashes."""
        self.assertEqual(memlint._extract_commit_citations("`e28e83a8`"), [])
        self.assertEqual(
            memlint._extract_commit_citations("gate at e28e83a8 today"), []
        )


class TestFileLineCitationRecognizer(unittest.TestCase):
    def test_plain_path_line_recognized(self):
        self.assertEqual(
            memlint._extract_file_line_citations("hooks/pre-edit-chain.sh:551 does X"),
            [("hooks/pre-edit-chain.sh", 551)],
        )

    def test_range_only_first_number_captured(self):
        self.assertEqual(
            memlint._extract_file_line_citations("mac-installer.sh:82-95 version gate"),
            [("mac-installer.sh", 82)],
        )

    def test_time_of_day_is_not_a_citation(self):
        self.assertEqual(memlint._extract_file_line_citations("session at 16:09 EDT"), [])

    def test_url_host_port_is_not_a_citation(self):
        self.assertEqual(
            memlint._extract_file_line_citations("see http://example.com:8080/x for details"), []
        )

    def test_backslash_joined_path_is_not_a_citation(self):
        """Fix round (Grok MINOR): a Windows-style "hooks\\missing.py:3"
        used to match starting right after the backslash, silently citing
        "missing.py" -- a different, real file at the store root, if one
        happened to exist -- instead of matching nothing. `\\` is now
        excluded from the lookbehind, same as the other path/word
        characters, so a backslash-preceded candidate is never a citation
        at all."""
        self.assertEqual(
            memlint._extract_file_line_citations("see hooks\\missing.py:3 for detail"), []
        )


class TestCitationsAgainstFixtureRepo(unittest.TestCase):
    """Acceptance 1-4: a real two-commit fixture repo, resolved through
    lint_root/--code-root exactly like code_refs already are."""

    def test_real_commit_citation_is_clean(self):
        with tempfile.TemporaryDirectory() as td_str:
            td = Path(td_str)
            code_root = td / "code"
            code_root.mkdir()
            first, first_subject, _second, _ = make_fixture_repo(code_root)
            store = td / "store"
            (store / "topics" / "memory").mkdir(parents=True)
            (store / "topics" / "memory" / "t.md").write_text(
                topic_md("TOP-CITE-OK", source=f"landed as commit {first}")
            )
            errors, _warnings = memlint.lint_root(store, code_roots=[code_root])
            self.assertFalse([e for e in errors if "cites commit" in e], errors)

    def test_altered_hash_by_one_character_is_a_warning_not_an_error(self):
        """Coordinator ruling 2026-09-19: a single --code-root cannot tell
        "fabricated" apart from "cites a different repository" -- so an
        unresolved hash is a WARNING by default, worded unverifiable, not
        an ERROR the checker cannot substantiate."""
        with tempfile.TemporaryDirectory() as td_str:
            td = Path(td_str)
            code_root = td / "code"
            code_root.mkdir()
            first, _subject, _second, _ = make_fixture_repo(code_root)
            bad_hash = ("f" if first[0] != "f" else "e") + first[1:]
            store = td / "store"
            (store / "topics" / "memory").mkdir(parents=True)
            (store / "topics" / "memory" / "t.md").write_text(
                topic_md("TOP-CITE-BADHASH", source=f"landed as commit {bad_hash}")
            )
            errors, warnings = memlint.lint_root(store, code_roots=[code_root])
            self.assertFalse([e for e in errors if "cites commit" in e], errors)
            hit = [w for w in warnings if "cites commit" in w]
            self.assertTrue(hit, warnings)
            self.assertIn(bad_hash, hit[0])
            self.assertIn("t.md", hit[0])
            self.assertIn("L1", hit[0])
            self.assertIn("unverifiable, not necessarily wrong", hit[0])

    def test_altered_hash_with_strict_citations_is_an_error_naming_it(self):
        """The same not-found hash, with --strict-citations: promoted to an
        ERROR, naming the record/link and the hash, no longer a warning."""
        with tempfile.TemporaryDirectory() as td_str:
            td = Path(td_str)
            code_root = td / "code"
            code_root.mkdir()
            first, _subject, _second, _ = make_fixture_repo(code_root)
            bad_hash = ("f" if first[0] != "f" else "e") + first[1:]
            store = td / "store"
            (store / "topics" / "memory").mkdir(parents=True)
            (store / "topics" / "memory" / "t.md").write_text(
                topic_md("TOP-CITE-BADHASH-STRICT", source=f"landed as commit {bad_hash}")
            )
            errors, warnings = memlint.lint_root(
                store, code_roots=[code_root], strict_citations=True
            )
            self.assertFalse([w for w in warnings if "cites commit" in w], warnings)
            hit = [e for e in errors if "cites commit" in e]
            self.assertTrue(hit, errors)
            self.assertIn(bad_hash, hit[0])
            self.assertIn("t.md", hit[0])
            self.assertIn("L1", hit[0])

    def test_wrong_quoted_subject_is_an_error_naming_both_subjects(self):
        """Substantiated mismatch -- the hash resolves -- so this stays an
        ERROR unconditionally, without --strict-citations."""
        with tempfile.TemporaryDirectory() as td_str:
            td = Path(td_str)
            code_root = td / "code"
            code_root.mkdir()
            first, first_subject, _second, _ = make_fixture_repo(code_root)
            store = td / "store"
            (store / "topics" / "memory").mkdir(parents=True)
            (store / "topics" / "memory" / "t.md").write_text(
                topic_md("TOP-CITE-BADSUBJ", source=f'commit {first} "Wrong subject entirely"')
            )
            errors, warnings = memlint.lint_root(store, code_roots=[code_root])
            self.assertFalse([w for w in warnings if "cites commit" in w], warnings)
            hit = [e for e in errors if "cites commit" in e]
            self.assertTrue(hit, errors)
            self.assertIn("Wrong subject entirely", hit[0])
            self.assertIn(first_subject, hit[0])

    def test_correct_quoted_subject_is_clean(self):
        with tempfile.TemporaryDirectory() as td_str:
            td = Path(td_str)
            code_root = td / "code"
            code_root.mkdir()
            first, first_subject, _second, _ = make_fixture_repo(code_root)
            store = td / "store"
            (store / "topics" / "memory").mkdir(parents=True)
            (store / "topics" / "memory" / "t.md").write_text(
                topic_md("TOP-CITE-GOODSUBJ", source=f'commit {first} "{first_subject}"')
            )
            errors, warnings = memlint.lint_root(store, code_roots=[code_root])
            self.assertFalse([e for e in errors if "cites commit" in e], errors)
            self.assertFalse([w for w in warnings if "cites commit" in w], warnings)

    def test_subject_differing_only_in_its_tail_is_an_error(self):
        """Fix round (both reviewers, MINOR): the earlier
        test_wrong_quoted_subject test used a subject wrong from its very
        first character ("Wrong subject entirely" vs "Add a.py with
        f()"), so even a compare of only the first few characters would
        have passed it -- not a real guard against a subject wrong only at
        the END. real_subject is "Add a.py with f()" (make_fixture_repo);
        cited as "Add a.py with g()", differing only in the one character
        right before the closing paren."""
        with tempfile.TemporaryDirectory() as td_str:
            td = Path(td_str)
            code_root = td / "code"
            code_root.mkdir()
            first, first_subject, _second, _ = make_fixture_repo(code_root)
            self.assertEqual(first_subject, "Add a.py with f()")
            wrong_tail_subject = "Add a.py with g()"
            store = td / "store"
            (store / "topics" / "memory").mkdir(parents=True)
            (store / "topics" / "memory" / "t.md").write_text(
                topic_md("TOP-CITE-TAILSUBJ", source=f'commit {first} "{wrong_tail_subject}"')
            )
            errors, warnings = memlint.lint_root(store, code_roots=[code_root])
            self.assertFalse([w for w in warnings if "cites commit" in w], warnings)
            hit = [e for e in errors if "cites commit" in e]
            self.assertTrue(hit, errors)
            self.assertIn(wrong_tail_subject, hit[0])
            self.assertIn(first_subject, hit[0])

    def test_correct_subject_with_doubled_internal_spaces_is_clean(self):
        """Fix round (both reviewers, MINOR): the earlier
        test_correct_quoted_subject test cited the subject byte-for-byte
        identical to the real one, so it never exercised whitespace
        normalization at all -- an exact-byte compare would have passed it
        too. A citation that preserves the real subject's WORDS but not its
        exact internal spacing must still be clean (docs/SCHEMA.md sec3:
        "compared after whitespace normalization")."""
        with tempfile.TemporaryDirectory() as td_str:
            td = Path(td_str)
            code_root = td / "code"
            code_root.mkdir()
            first, first_subject, _second, _ = make_fixture_repo(code_root)
            self.assertEqual(first_subject, "Add a.py with f()")
            doubled_space_subject = "Add  a.py with  f()"
            store = td / "store"
            (store / "topics" / "memory").mkdir(parents=True)
            (store / "topics" / "memory" / "t.md").write_text(
                topic_md("TOP-CITE-DBLSPACE", source=f'commit {first} "{doubled_space_subject}"')
            )
            errors, warnings = memlint.lint_root(store, code_roots=[code_root])
            self.assertFalse([e for e in errors if "cites commit" in e], errors)
            self.assertFalse([w for w in warnings if "cites commit" in w], warnings)

    def test_file_line_citation_short_file_is_error_without_strict(self):
        """Substantiated mismatch -- the file exists -- so this stays an
        ERROR unconditionally, without --strict-citations."""
        with tempfile.TemporaryDirectory() as td_str:
            td = Path(td_str)
            code_root = td / "code"
            code_root.mkdir()
            (code_root / "x.py").write_text("one\ntwo\nthree\n")
            store = td / "store"
            (store / "incidents").mkdir(parents=True)
            (store / "incidents" / "i.md").write_text(
                incident_md("INC-CITE-SHORT", evidence=["x.py:10 is where it happens"])
            )
            errors, warnings = memlint.lint_root(store, code_roots=[code_root])
            self.assertFalse([w for w in warnings if "x.py" in w], warnings)
            hit = [e for e in errors if "x.py" in e]
            self.assertTrue(hit, errors)
            self.assertIn("only 3 line", hit[0])

    def test_file_line_citation_missing_file_is_a_warning_not_an_error(self):
        """The same "not found" rule applies to file:line citations as to
        commits: unresolved, not substantiated, so a WARNING by default."""
        with tempfile.TemporaryDirectory() as td_str:
            td = Path(td_str)
            code_root = td / "code"
            code_root.mkdir()
            store = td / "store"
            (store / "incidents").mkdir(parents=True)
            (store / "incidents" / "i.md").write_text(
                incident_md("INC-CITE-MISSING", evidence=["nope.py:5 is where it happens"])
            )
            errors, warnings = memlint.lint_root(store, code_roots=[code_root])
            self.assertFalse([e for e in errors if "nope.py" in e], errors)
            hit = [w for w in warnings if "nope.py" in w]
            self.assertTrue(hit, warnings)
            self.assertIn("not found", hit[0])
            self.assertIn("unverifiable, not necessarily wrong", hit[0])

    def test_file_line_citation_missing_file_with_strict_citations_is_an_error(self):
        with tempfile.TemporaryDirectory() as td_str:
            td = Path(td_str)
            code_root = td / "code"
            code_root.mkdir()
            store = td / "store"
            (store / "incidents").mkdir(parents=True)
            (store / "incidents" / "i.md").write_text(
                incident_md("INC-CITE-MISSING-STRICT", evidence=["nope.py:5 is where it happens"])
            )
            errors, warnings = memlint.lint_root(
                store, code_roots=[code_root], strict_citations=True
            )
            self.assertFalse([w for w in warnings if "nope.py" in w], warnings)
            hit = [e for e in errors if "nope.py" in e]
            self.assertTrue(hit, errors)
            self.assertIn("not found", hit[0])

    def test_file_line_citation_enough_lines_is_clean(self):
        with tempfile.TemporaryDirectory() as td_str:
            td = Path(td_str)
            code_root = td / "code"
            code_root.mkdir()
            (code_root / "x.py").write_text("\n".join(str(i) for i in range(20)) + "\n")
            store = td / "store"
            (store / "incidents").mkdir(parents=True)
            (store / "incidents" / "i.md").write_text(
                incident_md("INC-CITE-ENOUGH", evidence=["x.py:10 is where it happens"])
            )
            errors, _warnings = memlint.lint_root(store, code_roots=[code_root])
            self.assertFalse([e for e in errors if "x.py" in e], errors)

    @unittest.skipUnless(hasattr(Path, "symlink_to"), "platform has no symlinks")
    def test_file_line_citation_resolves_through_a_symlinked_root(self):
        """Regression (first CI run, macOS): a code root reached through a
        symlinked path component (macOS's own /var -> /private/var, where
        tempfile lands) used to report an EXISTING, too-short file as "not
        found" -- `full.relative_to(root)` raised ValueError because `full`
        was resolved (following the symlink) while `root` was not.
        code_roots must be resolved up front, exactly like lint_concept's
        own resolved_roots, so a citation against a real file is always
        substantiated (an ERROR: too few lines), never misreported as
        unresolved (a WARNING: not found)."""
        with tempfile.TemporaryDirectory() as td_str:
            real = Path(td_str)
            (real / "realdir").mkdir()
            link = real / "linkdir"
            try:
                link.symlink_to(real / "realdir")
            except OSError:
                self.skipTest("could not create a symlink in this environment")
            code_root = link / "code"
            code_root.mkdir()
            (code_root / "x.py").write_text("one\ntwo\nthree\n")
            store = link / "store"
            (store / "incidents").mkdir(parents=True)
            (store / "incidents" / "i.md").write_text(
                incident_md("INC-CITE-SYMLINK", evidence=["x.py:10 is where it happens"])
            )
            errors, warnings = memlint.lint_root(store, code_roots=[code_root])
            self.assertFalse([w for w in warnings if "x.py" in w], warnings)
            hit = [e for e in errors if "x.py" in e]
            self.assertTrue(hit, errors)
            self.assertIn("only 3 line", hit[0])


class TestNoCodeRootSkipsCitationCheckSilently(unittest.TestCase):
    """Acceptance 5: without --code-root, the citation check is skipped and
    prints nothing about citations at all -- not merely "no error", no
    line mentioning a citation."""

    def test_bad_hash_with_no_code_root_is_clean_and_silent(self):
        with tempfile.TemporaryDirectory() as td_str:
            td = Path(td_str)
            store = td / "store"
            (store / "topics" / "memory").mkdir(parents=True)
            (store / "topics" / "memory" / "t.md").write_text(
                topic_md("TOP-CITE-NOROOT", source="landed as commit 0000000")
            )
            errors, warnings = memlint.lint_root(store)
            self.assertEqual(errors, [])
            self.assertFalse([w for w in warnings if "cite" in w.lower()], warnings)


class TestNonGitCodeRootSkipsCommitCheckOnly(unittest.TestCase):
    """A --code-root that exists on disk but is not a git repository (the
    shape every pre-existing code_roots test in test_memlint.py already
    uses) must not error on a commit citation -- only file:line citations,
    which need no git, still run."""

    def test_non_git_root_is_silent_on_commit_citations(self):
        with tempfile.TemporaryDirectory() as td_str:
            td = Path(td_str)
            code_root = td / "plain"
            code_root.mkdir()
            store = td / "store"
            (store / "topics" / "memory").mkdir(parents=True)
            (store / "topics" / "memory" / "t.md").write_text(
                topic_md("TOP-CITE-NONGIT", source="landed as commit 0000000")
            )
            errors, _warnings = memlint.lint_root(store, code_roots=[code_root])
            self.assertFalse([e for e in errors if "cites commit" in e], errors)

    def test_nonexistent_code_root_never_crashes(self):
        """A typo'd --code-root (does not exist on disk at all) must behave
        like every other --code-root consumer -- report "not found", never
        raise. _run_git's underlying subprocess.run raises FileNotFoundError
        on a missing cwd; _is_git_repo must swallow that as "not a git
        repo", not let it propagate as an uncaught GitError."""
        with tempfile.TemporaryDirectory() as td_str:
            td = Path(td_str)
            nope = td / "does-not-exist"
            store = td / "store"
            (store / "topics" / "memory").mkdir(parents=True)
            (store / "topics" / "memory" / "t.md").write_text(
                topic_md("TOP-CITE-NOROOT2", source="landed as commit abc1234")
            )
            errors, _warnings = memlint.lint_root(store, code_roots=[nope])
            self.assertFalse([e for e in errors if "cites commit" in e], errors)

    def test_non_git_root_still_checks_file_line(self):
        """file:line checking needs no git -- still runs against a plain
        (non-git) root. Unresolved (not found) is now a warning, not an
        error; the point of this test is that it is REPORTED at all."""
        with tempfile.TemporaryDirectory() as td_str:
            td = Path(td_str)
            code_root = td / "plain"
            code_root.mkdir()
            store = td / "store"
            (store / "incidents").mkdir(parents=True)
            (store / "incidents" / "i.md").write_text(
                incident_md("INC-CITE-NONGIT-FL", evidence=["nope.py:5 is where it happens"])
            )
            errors, warnings = memlint.lint_root(store, code_roots=[code_root])
            self.assertFalse([e for e in errors if "nope.py" in e], errors)
            self.assertTrue([w for w in warnings if "nope.py" in w], warnings)


class TestCommitResolutionMutation(unittest.TestCase):
    """Acceptance 7: stub cat-file to always succeed and confirm the
    altered-hash-under-strict test
    (test_altered_hash_with_strict_citations_is_an_error_naming_it) fails as
    a test -- proving that test actually exercises _commit_resolves rather
    than passing for an unrelated reason.

    Fix round (Opus MAJOR): the ORIGINAL version of this test asserted on
    `errors` without `strict_citations=True` -- but an unresolved hash is a
    WARNING by default (coordinator ruling), never in `errors` either way,
    so the assertion passed whether or not the mock had any effect at all
    (verified: it still passed with `return_value=False`, i.e. cat-file
    behaving normally). Fixed by running under strict, where an unresolved
    hash IS an error, and by putting the unmocked arm in the SAME test so
    the flip -- normally an error, wrongly clean once cat-file is stubbed to
    always succeed -- is actually demonstrated, not merely asserted."""

    def test_stubbed_commit_resolves_makes_the_strict_bad_hash_case_pass_wrongly(self):
        with tempfile.TemporaryDirectory() as td_str:
            td = Path(td_str)
            code_root = td / "code"
            code_root.mkdir()
            first, _subject, _second, _ = make_fixture_repo(code_root)
            bad_hash = ("f" if first[0] != "f" else "e") + first[1:]
            store = td / "store"
            (store / "topics" / "memory").mkdir(parents=True)
            (store / "topics" / "memory" / "t.md").write_text(
                topic_md("TOP-CITE-MUTATION", source=f"landed as commit {bad_hash}")
            )
            # Unmocked (real cat-file): the fabricated hash is correctly
            # flagged under --strict-citations.
            errors, _warnings = memlint.lint_root(
                store, code_roots=[code_root], strict_citations=True
            )
            self.assertTrue([e for e in errors if "cites commit" in e], errors)
            # Mocked (cat-file stubbed to always succeed): the same
            # fabricated hash is now (wrongly) accepted -- the flip that
            # demonstrates this test actually exercises _commit_resolves.
            with mock.patch.object(memlint, "_commit_resolves", return_value=True):
                errors, _warnings = memlint.lint_root(
                    store, code_roots=[code_root], strict_citations=True
                )
            self.assertFalse([e for e in errors if "cites commit" in e], errors)


class TestStrictCitationsFlagParsing(unittest.TestCase):
    """--strict-citations is pulled out of argv before parse_argv sees it
    (mirrors _extract_against_ref_flags's own preprocessing pass) -- parse_argv's
    3-tuple contract is untouched."""

    def test_flag_present_is_stripped_and_reported(self):
        rest, strict = memlint._extract_strict_citations_flag(
            ["S", "--code-root", "A", "--strict-citations"]
        )
        self.assertEqual(rest, ["S", "--code-root", "A"])
        self.assertTrue(strict)

    def test_flag_absent_is_false_and_argv_unchanged(self):
        rest, strict = memlint._extract_strict_citations_flag(["S", "--code-root", "A"])
        self.assertEqual(rest, ["S", "--code-root", "A"])
        self.assertFalse(strict)

    def test_parse_argv_contract_unaffected(self):
        rest, strict = memlint._extract_strict_citations_flag(
            ["S", "--strict-citations", "--code-root", "A"]
        )
        root, code_roots, unknown = memlint.parse_argv(rest)
        self.assertEqual(root, "S")
        self.assertEqual(code_roots, ["A"])
        self.assertIsNone(unknown)
        self.assertTrue(strict)


class TestStrictCitationsEndToEnd(unittest.TestCase):
    """main() itself, not just lint_root -- confirms the flag actually
    reaches the exit code a real invocation would produce."""

    def _store_with_unresolved_hash(self, td: Path) -> Path:
        store = td / "store"
        (store / "topics" / "memory").mkdir(parents=True)
        (store / "topics" / "memory" / "t.md").write_text(
            topic_md("TOP-CITE-CLI", source="landed as commit 0000000")
        )
        return store

    def test_without_strict_flag_exits_zero(self):
        with tempfile.TemporaryDirectory() as td_str:
            td = Path(td_str)
            code_root = td / "code"
            code_root.mkdir()
            make_fixture_repo(code_root)
            store = self._store_with_unresolved_hash(td)
            rc = memlint.main([str(store), "--code-root", str(code_root)])
            self.assertEqual(rc, 0)

    def test_with_strict_flag_exits_one(self):
        with tempfile.TemporaryDirectory() as td_str:
            td = Path(td_str)
            code_root = td / "code"
            code_root.mkdir()
            make_fixture_repo(code_root)
            store = self._store_with_unresolved_hash(td)
            rc = memlint.main(
                [str(store), "--code-root", str(code_root), "--strict-citations"]
            )
            self.assertEqual(rc, 1)

    def test_strict_citations_is_rejected_together_with_against_ref(self):
        """Fix round (NIT): --strict-citations under --against-ref used to
        be silently stripped and ignored -- inconsistent with --code-root's
        own explicit rejection in that same mode, for the identical reason
        (append-only mode never uses a code root). Same message shape."""
        import contextlib
        import io

        with tempfile.TemporaryDirectory() as td_str:
            store = Path(td_str)
            buf = io.StringIO()
            with contextlib.redirect_stderr(buf):
                rc = memlint.main(
                    ["--against-ref", "HEAD", "--strict-citations", str(store)]
                )
            self.assertEqual(rc, 2)
            self.assertIn(
                "--strict-citations is rejected together with --against-ref",
                buf.getvalue(),
            )


if __name__ == "__main__":
    unittest.main()
