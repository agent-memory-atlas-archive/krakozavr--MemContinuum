"""process-note-review-dispatch-python-env: the suite must fail LOUDLY, not
skip silently, when $MEMCONTINUUM_PYTHON is unset.

Today, dozens of whole test classes (tree-sitter chunkers, embeddings,
repo-init dependency reconciliation, the real-bash write-hook suites, ...)
are gated with `@unittest.skipUnless(VENV_PYTHON, _SKIP_NO_VENV)` -- correct
and deliberate (a machine without the pinned venv genuinely cannot run
them), but the net effect on a machine that forgot to set the variable is a
quiet "OK (skipped=N)" that reads exactly like a healthy, fully-covered run.
This one guard test fails the run instead, naming the missing variable and
how much coverage silently vanished, unless the operator explicitly opts
into an ungated run with $MEMCONTINUUM_ALLOW_UNGATED=1 -- CI already sets
$MEMCONTINUUM_PYTHON (.github/workflows/tests.yml), so this never fires
there.

INC-0125 adds the second half of the same idea: a real engine .venv/ next
to this checkout is ALSO an unstated precondition, in the other direction --
six tests across tests/test_hooks.py, tests/test_repo_init.py and
tests/test_write_hooks.py exist to prove a python resolves through the
config-pointer chain specifically when no engine venv is present to mask a
broken chain, and silently skip that proof (now correctly -- they used to
FAIL, which is the bug this file's second guard exists to catch) whenever
one exists. The same $MEMCONTINUUM_ALLOW_UNGATED=1 opt-out covers it: "I
accept the skipped coverage" means the same thing whichever direction the
missing precondition points.
"""
import os
import unittest
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
TOOLS_DIR = TESTS_DIR.parent


def _venv_gated_test_classes():
    """Every TestCase class, across tests/test_*.py, that unittest itself
    has marked skipped (`__unittest_skip__` set on the CLASS, not just an
    individual method) for a venv-related reason -- discovered by
    re-walking the same suite the real run already built (test modules are
    already in sys.modules by the time this runs, so `discover` re-imports
    nothing; it only re-collects), so this reflects the CURRENT process's
    real environment exactly, including subclasses that inherit their
    gating from a decorated base class (e.g. tests/test_update.py's
    UpdateTestBase) rather than carrying their own decorator."""
    loader = unittest.defaultTestLoader
    suite = loader.discover(start_dir=str(TESTS_DIR), pattern="test_*.py")
    seen: set = set()
    gated: list = []

    def walk(node):
        for item in node:
            if isinstance(item, unittest.TestSuite):
                walk(item)
            else:
                cls = item.__class__
                if cls in seen:
                    continue
                seen.add(cls)
                if getattr(cls, "__unittest_skip__", False):
                    why = getattr(cls, "__unittest_skip_why__", "") or ""
                    if "MEMCONTINUUM_PYTHON" in why:
                        gated.append(cls)

    walk(suite)
    return gated


class TestSuiteRefusesToSkipTheVenvGateSilently(unittest.TestCase):
    def test_memcontinuum_python_must_be_set_or_explicitly_waived(self):
        if os.environ.get("MEMCONTINUUM_PYTHON", ""):
            return  # the common case -- nothing to guard
        if os.environ.get("MEMCONTINUUM_ALLOW_UNGATED", "") == "1":
            return  # explicit operator opt-in -- accepted, not silent
        gated = _venv_gated_test_classes()
        self.fail(
            f"$MEMCONTINUUM_PYTHON is not set: {len(gated)} test class(es) will "
            "silently skip every one of their tests (tree-sitter chunkers, "
            "embeddings, repo-init dependency reconciliation, the real-bash "
            "write-hook suites, ...) -- see README.md's 'Running the tests' "
            "section. Set $MEMCONTINUUM_PYTHON to a venv python with the pinned "
            "dependencies installed, or set $MEMCONTINUUM_ALLOW_UNGATED=1 to run "
            "without it anyway, accepting the skipped coverage."
        )


class TestSuiteRefusesAnEngineVenvSilently(unittest.TestCase):
    """INC-0125: the suite polluted its own checkout with a real engine
    .venv/ (tests/test_update.py's TestEveryUnfinishedApplyRowFailsTheWalk
    used to reach memcontinuum-update.sh's real, uncopied sibling
    memcontinuum-setup.sh with no python resolvable anywhere, and that
    script bootstraps a venv at its own $SCRIPT_DIR/.venv by default --
    fixed by passing --no-machine, since that test is about a row's exit
    code, not the machine layer). Six tests exist specifically to prove the
    pre-edit hook and the post-commit reindex resolve a python through the
    config-pointer chain with NO engine venv present, and for two days they
    silently FAILED instead of proving anything, read as environmental
    noise. They now SKIP instead when the precondition they cannot control
    is unmet (see tests/test_hooks.py, tests/test_repo_init.py,
    tests/test_write_hooks.py) -- but a skip is still silently-missing
    coverage. This guard states the precondition loudly instead of letting
    a runner infer it from six skips with no obvious common cause."""

    def test_no_engine_venv_or_explicitly_waived(self):
        venv_python = TOOLS_DIR / ".venv" / "bin" / "python"
        if not venv_python.exists():
            return  # the common case -- nothing to guard
        if os.environ.get("MEMCONTINUUM_ALLOW_UNGATED", "") == "1":
            return  # explicit operator opt-in -- accepted, not silent
        self.fail(
            f"an engine .venv exists at {venv_python}: six tests across "
            "tests/test_hooks.py, tests/test_repo_init.py and "
            "tests/test_write_hooks.py cannot prove what they exist to prove "
            "(that a python resolves through the config-pointer chain with "
            "no engine venv present) and will silently skip instead of "
            "running. Remove it -- memcontinuum-setup.sh and "
            "scripts/repo-init.sh's --bootstrap-venv both default to "
            "creating it at THIS checkout's own .venv/, never a disposable "
            "directory, whenever something invokes either with no --python "
            "and none resolvable (see INC-0125) -- or set "
            "$MEMCONTINUUM_ALLOW_UNGATED=1 to run anyway, accepting the "
            "skipped coverage."
        )
