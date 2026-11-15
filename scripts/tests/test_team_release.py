#!/usr/bin/env python3
"""Tests for scripts/team_release.py against a fake GitHub. No test calls the real gh or git, or the network."""
import ast
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import re
import shutil
import signal
import sys
import tempfile
import unittest
import urllib.parse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/team_release.py"
spec = importlib.util.spec_from_file_location("team_release", SCRIPT)
tr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tr)

SHA = "0123456789abcdef0123456789abcdef01234567"
OTHER_SHA = "fedcba9876543210fedcba9876543210fedcba98"
V = "2.5.640"
TAG = "v" + V
TITLE = "release %s %s" % (V, SHA)
INSTALLER = "PokeTokenBar-Setup-2.5.640-win-x64.exe"
REPO_ARGS = ["--repo", "likelion-campus/PokeTokenBar"]
API = "repos/likelion-campus/PokeTokenBar/"
LIST = API + "releases?per_page=100"
LATEST = API + "releases/latest"
INSTALLER_BYTES = b"MZ a fake installer " * 1000
ZIP_BYTES = b"PK a fake zip " * 500
WORKFLOW_NAMES = {"windows-app.yml": "windows-app", "windows.yml": "windows",
                  "windows-release-smoke.yml": "windows-release-smoke"}


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def opt(args, name):
    return args[args.index(name) + 1] if name in args else None


def ok(out=""):
    return tr.Result(0, out, "")


def is_call(*prefix):
    return lambda argv: argv[1:1 + len(prefix)] == list(prefix)


def nth(n, predicate):
    """A predicate true on the n-th (1-based) call that `predicate` matches."""
    seen = [0]

    def check(argv):
        if predicate(argv):
            seen[0] += 1
            return seen[0] == n
        return False
    return check


class FakeClock:
    def __init__(self):
        self.t, self.sleeps = 0.0, []

    def now(self):
        return self.t

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.t += seconds


class FakeGitHub:
    """`gh` and `git ls-remote` for likelion-campus/PokeTokenBar, with state. Every call is recorded, and a call that
    is not pinned to the fork fails the test. GitHub and gh behave as the helper assumes (A1-A6 in its docstring):
      A1 create --draft makes a draft with the pending tag and no git tag; publishing creates the tag at the target.
      A2 release edit/delete <tag> act on one release with that tag: a published one first, else one of the drafts
         (`pick` says which, as GraphQL would; GitHub allows several drafts with one tag).
      A3 assets uploaded to a draft are `uploaded`, with digest sha256:<hex> of the uploaded bytes.
      A4 edit --draft=false --latest publishes and makes the release latest.
      A5 with --draft, create never checks for an existing release, and a failed upload leaves the draft (with the
         assets uploaded so far) in place.
      A6 the REST list has every release (drafts too), newest first; releases/latest is the latest published one.
    Runs have attempts, and a dispatch cancels a pending run of the same release (concurrency group
    <workflow>-release-<sha>, cancel-in-progress false: one running, one pending).
    Faults are injected with `on(predicate, effect)`: an effect returns a Result to answer instead, or None to change
    state and let the default answer follow."""

    def __init__(self):
        self.calls, self.hooks = [], []
        self.releases, self.tags, self.latest, self.pick = [], {}, None, "first"
        self.runs, self.hidden, self.timelines, self.artifacts = {}, {}, {}, {}
        self.appear_after = 1          # `gh run list` calls before a dispatched run shows; None = never
        self.upload_fails_after = None  # create uploads this many assets, then fails
        self.workflow_files = set()     # (ref, file name) the contents API knows
        self.next_id, self.stamp = 9000, 0

    def on(self, predicate, effect):
        self.hooks.append((predicate, effect))

    def __call__(self, argv):
        argv = list(argv)
        self._check_pinned(argv)
        self.calls.append(argv)
        for predicate, effect in list(self.hooks):
            if predicate(argv):
                result = effect(argv)
                if result is not None:
                    return result
        if argv[0] == "git":
            return self._ls_remote(argv[3])
        if argv[1] == "api":
            return self._api(argv[2])
        args = argv[1:-2]
        handler = getattr(self, "_%s_%s" % (args[0], args[1]), None)
        assert handler is not None, "unexpected call %s" % argv
        return handler(args[2:])

    @staticmethod
    def _check_pinned(argv):
        if argv[0] == "git":
            assert argv[:3] == ["git", "ls-remote", "https://github.com/likelion-campus/PokeTokenBar.git"], argv
            assert len(argv) == 4 and argv[3].startswith("refs/tags/v"), argv
        elif argv[:2] == ["gh", "api"]:
            assert len(argv) == 3 and argv[2].startswith(API), argv
        else:
            assert argv[0] == "gh" and argv[-2:] == REPO_ARGS and argv.count("--repo") == 1, argv
        assert not {"push", "--cleanup-tag", "-X", "--method", "-R"} & set(argv), argv
        assert "chattymin" not in " ".join(argv), argv

    # helpers for tests

    def compact(self):
        """The calls as 'gh release create', 'gh api releases', 'gh api releases/latest', 'git ls-remote' ..."""
        names = []
        for argv in self.calls:
            if argv[0] == "git":
                names.append("git ls-remote")
            elif argv[1] == "api":
                names.append("gh api " + argv[2][len(API):].split("?")[0])
            else:
                names.append("gh %s %s" % (argv[1], argv[2]))
        return names

    def calls_of(self, *prefix):
        return [argv for argv in self.calls if argv[1:1 + len(prefix)] == list(prefix)]

    def add_run(self, workflow, title=TITLE, status="completed", conclusion="success", event="workflow_dispatch"):
        self.next_id += 1
        self.stamp += 1
        run = {"databaseId": self.next_id, "displayTitle": title, "status": status, "conclusion": conclusion,
               "event": event, "createdAt": "2026-11-16T10:%02d:00Z" % self.stamp, "attempt": 1,
               "workflowName": WORKFLOW_NAMES[workflow], "workflow": workflow}
        self.runs.setdefault(workflow, []).append(run)
        return self.next_id

    def run_by_id(self, run_id):
        for runs in self.runs.values():
            for run in runs:
                if run["databaseId"] == run_id:
                    return run
        return None

    def rerun(self, run_id, after=1, conclusion="success"):
        """`gh run rerun`: the same run id, the next attempt."""
        run = self.run_by_id(run_id)
        run["attempt"] += 1
        run["status"], run["conclusion"] = "queued", ""
        self.timelines[run_id] = [("in_progress", "")] * after + [("completed", conclusion)]

    def find(self, tag):
        published = [release for release in self.releases if not release["draft"] and release["tag"] == tag]
        drafts = [release for release in self.releases if release["draft"] and release["tag"] == tag]
        if published:
            return published[0]
        if drafts:
            return drafts[0] if self.pick == "first" else drafts[-1]
        return None

    def tagged(self, tag):
        return [release for release in self.releases if release["tag"] == tag]

    def add_release(self, tag, draft, target=SHA, assets=None):
        self.next_id += 1
        release = {"id": self.next_id, "tag": tag, "draft": draft, "target": target, "assets": assets or []}
        self.releases.append(release)
        if not draft:
            self.tags[tag] = target
            self.latest = tag
        return release

    def rest(self, release):
        url = "https://github.com/likelion-campus/PokeTokenBar/releases/tag/" + (
            "untagged-%d" % release["id"] if release["draft"] else release["tag"])
        return {"id": release["id"], "tag_name": release["tag"], "draft": release["draft"],
                "target_commitish": release["target"], "html_url": url,
                "assets": [dict(asset) for asset in release["assets"]]}

    # gh run / workflow

    def _run_list(self, args):
        workflow, event, limit = opt(args, "--workflow"), opt(args, "--event"), int(opt(args, "--limit"))
        fields = opt(args, "--json").split(",")
        shown = []
        for run in self.runs.get(workflow, []):
            left = self.hidden.get(run["databaseId"], 0)
            if left is not None and left > 0:
                left -= 1
                self.hidden[run["databaseId"]] = left
            if left == 0 and (event is None or run["event"] == event):
                shown.append(run)
        shown.sort(key=lambda run: run["createdAt"], reverse=True)
        return ok(json.dumps([{key: run[key] for key in fields} for run in shown[:limit]]))

    def _workflow_run(self, args):
        workflow, ref = args[0], opt(args, "--ref")
        inputs = dict(value.split("=", 1) for flag, value in zip(args, args[1:]) if flag == "-f")
        title = ("release %s %s" % (inputs.get("release_version"), inputs.get("release_sha"))
                 if workflow != "windows-release-smoke.yml" else "windows-release-smoke")
        for run in self.runs.get(workflow, []):
            if run["displayTitle"] == title and run["status"] in ("queued", "pending", "waiting"):
                run["status"], run["conclusion"] = "completed", "cancelled"  # the newer pending run replaces it
                self.timelines.pop(run["databaseId"], None)
        run_id = self.add_run(workflow, title, "queued", "")
        self.hidden[run_id] = self.appear_after
        return ok("https://github.com/likelion-campus/PokeTokenBar/actions/runs/%d\n" % run_id)

    def _run_view(self, args):
        run = self.run_by_id(int(args[0]))
        if run is None:
            return tr.Result(1, "", "could not find any workflow run with ID %s\n" % args[0])
        timeline = self.timelines.get(run["databaseId"])
        if timeline:
            run["status"], run["conclusion"] = timeline.pop(0) if len(timeline) > 1 else timeline[0]
        return ok(json.dumps({key: run[key] for key in opt(args, "--json").split(",")}))

    def _run_download(self, args):
        files = self.artifacts.get((int(args[0]), opt(args, "--name")))
        if files is None:
            return tr.Result(1, "", "no artifact matches any of the names or patterns provided\n")
        dest = Path(opt(args, "--dir"))
        for name, data in files.items():
            (dest / name).write_bytes(data)
        return ok()

    # gh release

    def _release_create(self, args):
        tag, target = args[0], opt(args, "--target")
        assert "--draft" in args and opt(args, "--title") == tag, args
        assert Path(opt(args, "--notes-file")).read_text().strip(), args
        files = []
        for arg in args[1:]:
            if arg.startswith("--"):
                break
            files.append(Path(arg))
        release = self.add_release(tag, True, target)
        for index, path in enumerate(files):
            if self.upload_fails_after is not None and index >= self.upload_fails_after:
                return tr.Result(1, "", "HTTP 502: upload of %s failed\n" % path.name)
            data = path.read_bytes()
            release["assets"].append({"name": path.name, "size": len(data), "state": "uploaded",
                                      "digest": "sha256:" + sha256(data)})
        return ok("https://github.com/likelion-campus/PokeTokenBar/releases/tag/untagged-%d\n" % release["id"])

    def _release_edit(self, args):
        release = self.find(args[0])
        if release is None:
            return tr.Result(1, "", "release not found\n")
        assert args[1:] == ["--draft=false", "--latest"], args
        release["draft"] = False
        self.tags.setdefault(release["tag"], release["target"])
        self.latest = release["tag"]
        return ok("https://github.com/likelion-campus/PokeTokenBar/releases/tag/%s\n" % release["tag"])

    def _release_delete(self, args):
        release = self.find(args[0])
        if release is None:
            return tr.Result(1, "", "release not found\n")
        assert args[1:] == ["--yes"], args
        self.releases.remove(release)
        return ok()

    # gh api, git

    def _api(self, path):
        not_found = tr.Result(1, '{"message":"Not Found","status":"404"}', "gh: Not Found (HTTP 404)\n")
        rest = path[len(API):]
        if rest == "releases/latest":
            release = next((r for r in self.releases if r["tag"] == self.latest and not r["draft"]), None)
            return ok(json.dumps(self.rest(release))) if release else not_found
        if rest == "releases?per_page=100":
            return ok(json.dumps([self.rest(release) for release in reversed(self.releases)]))
        if rest.startswith("contents/.github/workflows/"):
            name, _, query = rest[len("contents/.github/workflows/"):].partition("?ref=")
            return ok('{"type":"file"}') if (urllib.parse.unquote(query), name) in self.workflow_files else not_found
        raise AssertionError("unexpected api path " + path)

    def _ls_remote(self, ref):
        tag = ref[len("refs/tags/"):]
        return ok("%s\t%s\n" % (self.tags[tag], ref) if tag in self.tags else "")


class SignalNotTaken(Exception):
    """Raised by the test's own SIGTERM/SIGHUP handler: the helper did not install its handler."""


def _not_taken(signum, frame):
    raise SignalNotTaken(signum)


class HelperTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        self.gh, self.clock = FakeGitHub(), FakeClock()
        # A signal the helper does not handle must fail the test, not kill the test run.
        for sig in (signal.SIGTERM, signal.SIGHUP):
            self.addCleanup(signal.signal, sig, signal.signal(sig, _not_taken))

    def run_helper(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        code = tr.main(list(argv), runner=self.gh, clock=self.clock, root=self.tmp, out=out, err=err)
        self.out, self.err = out.getvalue(), err.getvalue()
        return code

    def assertExit(self, expected, code):
        self.assertEqual(expected, code, "exit %d\nstdout:\n%s\nstderr:\n%s" % (code, self.out, self.err))


# ── start ──────────────────────────────────────────────────────────────────────────────────────────────────────


class StartTests(HelperTest):
    def start(self, *extra):
        return self.run_helper("start", "--sha", SHA, "--version", V, *extra)

    def runs_file(self):
        return json.loads((self.tmp / "build/windows-release/runs.json").read_text())

    def test_reuses_green_runs(self):
        app, tests = self.gh.add_run("windows-app.yml"), self.gh.add_run("windows.yml")
        self.assertExit(0, self.start())
        self.assertEqual([], self.gh.calls_of("workflow", "run"))
        self.assertIn("WINDOWS_APP_RUN=%d\n" % app, self.out)
        self.assertIn("WINDOWS_TESTS_RUN=%d\n" % tests, self.out)
        self.assertIn("attempt 1", self.err)
        self.assertEqual({"schema": 1, "sha": SHA, "version": V, "ref": "main",
                          "runs": {"windows-app.yml": app, "windows.yml": tests}}, self.runs_file())

    def test_lists_runs_with_the_exact_query(self):
        self.gh.add_run("windows-app.yml")
        self.gh.add_run("windows.yml")
        self.start()
        self.assertEqual(["gh", "run", "list", "--workflow", "windows-app.yml", "--event", "workflow_dispatch", "--json",
                          "databaseId,displayTitle,status,conclusion,event,createdAt,attempt", "--limit", "50"] + REPO_ARGS,
                         self.gh.calls[0])

    def test_reuses_a_running_or_queued_run(self):
        app = self.gh.add_run("windows-app.yml", status="in_progress", conclusion="")
        tests = self.gh.add_run("windows.yml", status="queued", conclusion="")
        self.assertExit(0, self.start())
        self.assertEqual([], self.gh.calls_of("workflow", "run"))
        self.assertEqual({"windows-app.yml": app, "windows.yml": tests}, self.runs_file()["runs"])

    def test_refuses_a_failed_run_and_starts_nothing(self):
        self.gh.add_run("windows-app.yml", conclusion="failure")
        self.assertExit(3, self.start())
        self.assertEqual([], self.gh.calls_of("workflow", "run"), "not even windows.yml, which has no run")
        self.assertIn("--new", self.err)
        self.assertFalse((self.tmp / "build/windows-release/runs.json").exists())

    def test_refuses_a_cancelled_or_timed_out_run(self):
        for conclusion in ("cancelled", "timed_out", "startup_failure"):
            with self.subTest(conclusion):
                self.gh = FakeGitHub()
                self.gh.add_run("windows-app.yml")
                self.gh.add_run("windows.yml", conclusion=conclusion)
                self.assertExit(3, self.start())
                self.assertEqual([], self.gh.calls_of("workflow", "run"))

    def test_the_newest_run_decides(self):
        self.gh.add_run("windows-app.yml", conclusion="success")
        self.gh.add_run("windows-app.yml", conclusion="failure")
        self.gh.add_run("windows.yml")
        self.assertExit(3, self.start())
        self.gh = FakeGitHub()
        self.gh.add_run("windows-app.yml", conclusion="failure")
        green = self.gh.add_run("windows-app.yml", conclusion="success")
        self.gh.add_run("windows.yml")
        self.assertExit(0, self.start())
        self.assertEqual(green, self.runs_file()["runs"]["windows-app.yml"])

    def test_new_replaces_only_the_failed_run(self):
        for flag in (("--new",), ("--new", "failed")):
            with self.subTest(flag):
                self.gh = FakeGitHub()
                failed = self.gh.add_run("windows-app.yml", conclusion="failure")
                tests = self.gh.add_run("windows.yml")
                self.assertExit(0, self.start(*flag))
                self.assertEqual(1, len(self.gh.calls_of("workflow", "run")))
                runs = self.runs_file()["runs"]
                self.assertNotEqual(failed, runs["windows-app.yml"])
                self.assertEqual(TITLE, self.gh.run_by_id(runs["windows-app.yml"])["displayTitle"])
                self.assertEqual(tests, runs["windows.yml"])

    def test_new_with_a_workflow_replaces_a_green_run(self):
        # The artifacts of a green run expire after 7 days; or its `first` is refused once a Windows release exists.
        green = self.gh.add_run("windows-app.yml")
        tests = self.gh.add_run("windows.yml")
        self.assertExit(0, self.start("--new", "windows-app.yml"))
        self.assertEqual(["windows-app.yml"], [argv[3] for argv in self.gh.calls_of("workflow", "run")])
        runs = self.runs_file()["runs"]
        self.assertNotEqual(green, runs["windows-app.yml"])
        self.assertEqual(tests, runs["windows.yml"])

    def test_new_with_a_workflow_does_not_excuse_the_other_failed_one(self):
        self.gh.add_run("windows-app.yml")
        self.gh.add_run("windows.yml", conclusion="failure")
        self.assertExit(3, self.start("--new", "windows-app.yml"))
        self.assertEqual([], self.gh.calls_of("workflow", "run"))

    def test_a_new_pending_run_cancels_the_older_pending_one(self):
        running = self.gh.add_run("windows-app.yml", status="in_progress", conclusion="")
        pending = self.gh.add_run("windows-app.yml", status="queued", conclusion="")
        self.gh.add_run("windows.yml")
        self.assertExit(0, self.start("--new", "windows-app.yml"))
        self.assertEqual(("completed", "cancelled"), (self.gh.run_by_id(pending)["status"],
                                                      self.gh.run_by_id(pending)["conclusion"]))
        self.assertEqual("in_progress", self.gh.run_by_id(running)["status"])
        self.assertNotIn(self.runs_file()["runs"]["windows-app.yml"], (running, pending))

    def test_rejects_an_unknown_workflow_for_new(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                self.start("--new", "windows-release-smoke.yml")

    def test_dispatches_both_when_there_is_none(self):
        self.gh.add_run("windows-app.yml", title="release %s %s" % (V, OTHER_SHA))  # another commit
        self.gh.add_run("windows-app.yml", title=TITLE, event="push")               # not a dispatch
        self.gh.appear_after = 3
        self.assertExit(0, self.start("--ref", "ci/windows-release-mode"))
        dispatches = self.gh.calls_of("workflow", "run")
        self.assertEqual([["gh", "workflow", "run", wf, "--ref", "ci/windows-release-mode", "-f", "release_sha=" + SHA,
                           "-f", "release_version=" + V] + REPO_ARGS for wf in ("windows-app.yml", "windows.yml")],
                         dispatches)
        runs = self.runs_file()["runs"]
        for wf in ("windows-app.yml", "windows.yml"):
            self.assertEqual(TITLE, self.gh.run_by_id(runs[wf])["displayTitle"])
        self.assertEqual([5] * 6, self.clock.sleeps, "polled in 5 s steps until each run showed")
        self.assertEqual("ci/windows-release-mode", self.runs_file()["ref"])

    def test_a_dispatched_run_that_never_appears(self):
        self.gh.appear_after = None
        self.assertExit(1, self.start())
        self.assertEqual(1, len(self.gh.calls_of("workflow", "run")))
        self.assertEqual(60, sum(self.clock.sleeps))
        self.assertTrue(all(step == 5 for step in self.clock.sleeps))
        self.assertIn("Run start again", self.err)
        self.assertFalse((self.tmp / "build/windows-release/runs.json").exists())

    def test_a_rerun_after_that_reuses_the_late_run(self):
        self.gh.appear_after = None
        self.assertExit(1, self.start())
        late = self.gh.runs["windows-app.yml"][0]["databaseId"]
        self.gh.hidden[late] = 0
        self.gh.appear_after = 1
        self.assertExit(0, self.start())
        self.assertEqual(late, self.runs_file()["runs"]["windows-app.yml"])
        self.assertEqual(["windows-app.yml", "windows.yml"], [argv[3] for argv in self.gh.calls_of("workflow", "run")])

    def test_a_failed_run_list_or_dispatch_exits_1(self):
        self.gh.on(is_call("run", "list"), lambda argv: tr.Result(1, "", "HTTP 401: Bad credentials\n"))
        self.assertExit(1, self.start())
        self.assertIn("Bad credentials", self.err)
        self.gh = FakeGitHub()
        self.gh.on(is_call("workflow", "run"), lambda argv: tr.Result(1, "", "HTTP 422: Unexpected inputs\n"))
        self.assertExit(1, self.start())
        self.assertIn("Unexpected inputs", self.err)
        self.assertFalse((self.tmp / "build/windows-release/runs.json").exists())

    def test_dry_run_prints_the_dispatch_and_writes_nothing(self):
        app = self.gh.add_run("windows-app.yml")
        self.assertExit(0, self.start("--dry-run"))
        self.assertEqual(["gh run list", "gh run list"], self.gh.compact())
        self.assertIn("DRY-RUN (not run): gh workflow run windows.yml --ref main -f release_sha=%s -f "
                      "release_version=%s --repo likelion-campus/PokeTokenBar" % (SHA, V), self.err)
        self.assertIn("WINDOWS_APP_RUN=%d" % app, self.out)
        self.assertNotIn("WINDOWS_TESTS_RUN", self.out)
        self.assertFalse((self.tmp / "build").exists())

    def test_rejects_a_short_sha_or_a_bad_version(self):
        with contextlib.redirect_stderr(io.StringIO()) as usage:
            with self.assertRaises(SystemExit) as raised:
                self.run_helper("start", "--sha", SHA[:7], "--version", V)
            self.assertEqual(2, raised.exception.code)
            with self.assertRaises(SystemExit):
                self.run_helper("start", "--sha", SHA, "--version", "v2.5.640")
        self.assertIn("expected x.y.z", usage.getvalue())
        self.assertEqual([], self.gh.calls)


# ── collect ────────────────────────────────────────────────────────────────────────────────────────────────────


def release_manifest(run_id, installer=INSTALLER_BYTES, attempt=1):
    return {"schema": 1, "sha": SHA, "workflowSha": "b" * 40, "version": V, "level": "full", "runId": run_id,
            "runAttempt": attempt, "runnerImage": "20261110.1.0", "swift": "6.3.2",
            "installer": {"name": INSTALLER, "size": len(installer), "sha256": sha256(installer),
                          "fileVersion": V + ".0", "productVersion": V, "isccDefines": ["SrcDir", "AppVer", "OutDir"]},
            "app": {"fileVersion": V + ".0", "versionFile": V, "uninstallDisplayVersion": V},
            "gates": {gate: "success" for gate in tr.REQUIRED_GATES}}


def tests_manifest():
    return {"schema": 1, "sha": SHA, "version": V, "executed": 2431, "skipped": 12, "failures": 0}


class CollectTests(HelperTest):
    def setUp(self):
        super().setUp()
        self.app = self.gh.add_run("windows-app.yml", status="in_progress", conclusion="")
        self.tests = self.gh.add_run("windows.yml", status="in_progress", conclusion="")
        path = self.tmp / "build/windows-release/runs.json"
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps({"schema": 1, "sha": SHA, "version": V, "ref": "main",
                                    "runs": {"windows-app.yml": self.app, "windows.yml": self.tests}}))
        self.finish(self.app, after=3)
        self.finish(self.tests, after=1)
        self.set_artifacts(release_manifest(self.app), tests_manifest())

    def finish(self, run_id, after, conclusion="success"):
        self.gh.timelines[run_id] = [("in_progress", "")] * after + [("completed", conclusion)]

    def set_artifacts(self, release, tests, installer=INSTALLER_BYTES, extra=None):
        files = {"windows-release.json": json.dumps(release).encode(), INSTALLER: installer}
        files.update(extra or {})
        self.gh.artifacts[(self.app, "windows-release")] = files
        self.gh.artifacts[(self.tests, "windows-tests")] = {"windows-tests.json": json.dumps(tests).encode()}

    def collect(self, *extra):
        return self.run_helper("collect", "--sha", SHA, "--version", V, "--out", str(self.tmp / "out"), *extra)

    def test_success_prints_the_installer_and_its_hash(self):
        self.assertExit(0, self.collect())
        installer = (self.tmp / "out/windows-release" / INSTALLER).resolve()
        self.assertEqual("INSTALLER=%s\nSHA256=%s\n" % (installer, sha256(INSTALLER_BYTES)), self.out)
        self.assertEqual(INSTALLER_BYTES, installer.read_bytes())
        self.assertEqual([60, 60, 60], self.clock.sleeps)
        downloads = self.gh.calls_of("run", "download")
        self.assertEqual(["gh", "run", "download", str(self.app), "--name", "windows-release", "--dir",
                          str(self.tmp / "out/windows-release")] + REPO_ARGS, downloads[0])
        self.assertEqual(["gh", "run", "view", str(self.app), "--json",
                          "status,conclusion,event,workflowName,displayTitle,attempt"] + REPO_ARGS,
                         self.gh.calls_of("run", "view")[0])
        self.assertIn("collect: windows-app.yml run %d attempt 1" % self.app, self.err)

    def test_prints_one_progress_line_per_five_minutes(self):
        self.finish(self.app, after=12)
        self.assertExit(0, self.collect())
        progress = [line for line in self.err.splitlines() if re.match(r"collect: \d+ min:", line)]
        self.assertEqual(["collect: 0 min:", "collect: 5 min:", "collect: 10 min:"],
                         [line.split(" windows")[0] for line in progress])

    def test_a_failed_or_cancelled_run_stops_before_any_download(self):
        for conclusion in ("failure", "cancelled", "timed_out"):
            with self.subTest(conclusion):
                self.gh.calls = []
                self.finish(self.app, after=3)
                self.finish(self.tests, after=1, conclusion=conclusion)
                self.assertExit(4, self.collect())
                self.assertIn("concluded %s" % conclusion, self.err)
                self.assertIn("/actions/runs/%d" % self.tests, self.err)
                self.assertEqual([], self.gh.calls_of("run", "download"))
                self.assertEqual("", self.out)

    def test_a_run_that_a_newer_dispatch_cancelled(self):
        # windows-app's pending release run is replaced by a newer dispatch for the same commit (concurrency group).
        self.gh.timelines.pop(self.app)
        self.gh.run_by_id(self.app).update(status="queued", conclusion="")
        self.gh.add_run("windows-app.yml", status="in_progress", conclusion="")
        self.gh("gh workflow run windows-app.yml --ref main -f release_sha={} -f release_version={} --repo "
                "likelion-campus/PokeTokenBar".format(SHA, V).split())
        self.assertEqual("cancelled", self.gh.run_by_id(self.app)["conclusion"])
        self.gh.calls = []
        self.assertExit(4, self.collect())
        self.assertIn("windows-app.yml run %d concluded cancelled" % self.app, self.err)

    def test_times_out(self):
        self.gh.timelines[self.app] = [("in_progress", "")]
        self.assertExit(4, self.collect())
        self.assertIn("timed out after 100 min", self.err)
        self.assertEqual(100 * 60, sum(self.clock.sleeps))
        self.assertEqual([], self.gh.calls_of("run", "download"))

    def test_the_timeout_can_be_shorter(self):
        self.gh.timelines[self.app] = [("queued", "")]
        self.assertExit(4, self.collect("--timeout-min", "5"))
        self.assertEqual(5 * 60, sum(self.clock.sleeps))

    def test_a_rerun_is_refused_unless_allowed(self):
        self.gh.rerun(self.app, after=2)
        self.set_artifacts(release_manifest(self.app, attempt=2), tests_manifest())
        self.assertExit(4, self.collect())
        self.assertIn("attempt 2, a re-run", self.err)
        self.assertIn("--allow-rerun", self.err)
        self.assertEqual([], self.gh.calls_of("run", "download"))
        self.gh.rerun(self.app, after=0)
        self.set_artifacts(release_manifest(self.app, attempt=3), tests_manifest())
        self.assertExit(0, self.collect("--allow-rerun"))
        self.assertIn("collect: windows-app.yml run %d attempt 3" % self.app, self.err)

    def test_a_rerun_of_the_tests_run_is_refused_too(self):
        self.gh.rerun(self.tests)
        self.assertExit(4, self.collect())
        self.assertIn("windows.yml run %d is attempt 2" % self.tests, self.err)

    def test_a_run_without_an_attempt_is_refused(self):
        # gh fills a missing run_attempt with its zero value.
        self.gh.run_by_id(self.app)["attempt"] = 0
        self.assertExit(4, self.collect())
        self.assertIn("run %d reports attempt 0" % self.app, self.err)

    def test_the_manifest_must_come_from_the_runs_attempt(self):
        self.set_artifacts(release_manifest(self.app, attempt=2), tests_manifest())
        self.assertExit(4, self.collect())
        self.assertIn("runAttempt (the run's attempt) is 2, expected 1", self.err)

    def test_a_run_of_another_workflow_title_or_event_is_refused(self):
        for change in ({"event": "push"}, {"displayTitle": "release %s %s" % (V, OTHER_SHA)},
                       {"workflowName": "windows-release-smoke"}):
            with self.subTest(change):
                run = self.gh.run_by_id(self.app)
                saved = dict(run)
                run.update(change)
                self.assertExit(4, self.collect())
                self.assertIn("is not a windows-app release run", self.err)
                run.clear()
                run.update(saved)

    def test_runs_json_for_another_release_is_refused(self):
        self.assertExit(4, self.run_helper("collect", "--sha", OTHER_SHA, "--version", V, "--out", str(self.tmp / "o")))
        self.assertIn("Run start first", self.err)
        self.assertEqual([], self.gh.calls)

    def test_runs_json_without_a_run_id_is_refused(self):
        path = self.tmp / "build/windows-release/runs.json"
        path.write_text(json.dumps({"schema": 1, "sha": SHA, "version": V, "runs": {"windows-app.yml": self.app}}))
        self.assertExit(4, self.collect())
        self.assertIn("has no run id for windows.yml", self.err)
        self.assertEqual([], self.gh.calls)

    def test_gh_output_that_is_not_json(self):
        self.gh.on(is_call("run", "view"), lambda argv: ok("<html>rate limited</html>"))
        self.assertExit(4, self.collect())
        self.assertIn("not JSON: <html>", self.err)

    def test_a_missing_runs_json_is_refused(self):
        (self.tmp / "build/windows-release/runs.json").unlink()
        self.assertExit(4, self.collect())
        self.assertEqual([], self.gh.calls)

    def test_reading_a_run_fails_three_times_in_a_row(self):
        self.gh.on(is_call("run", "view"), lambda argv: tr.Result(1, "", "HTTP 502\n"))
        self.assertExit(4, self.collect())
        self.assertIn("three times in a row", self.err)

    def test_one_failed_read_is_tolerated(self):
        self.gh.on(nth(1, is_call("run", "view")), lambda argv: tr.Result(1, "", "HTTP 502\n"))
        self.assertExit(0, self.collect())

    def mismatch(self, mutate_release=None, mutate_tests=None, installer=INSTALLER_BYTES, extra=None):
        release, tests = release_manifest(self.app), tests_manifest()
        if mutate_release:
            mutate_release(release)
        if mutate_tests:
            mutate_tests(tests)
        self.set_artifacts(release, tests, installer, extra)
        code = self.collect()
        self.assertExit(4, code)
        self.assertEqual("", self.out)
        return self.err

    def test_manifest_mismatches_are_refused(self):
        cases = {
            "another sha": (lambda m: m.update(sha=OTHER_SHA), "windows-release.json sha"),
            "another version": (lambda m: m.update(version="2.5.639"), "windows-release.json version"),
            "level light": (lambda m: m.update(level="light"), "windows-release.json level"),
            "a failed gate": (lambda m: m["gates"].update(idle="failure"), "gate idle is \"failure\""),
            "a skipped gate": (lambda m: m["gates"].update(uninstall="skipped"), "gate uninstall"),
            "a missing gate": (lambda m: m["gates"].pop("installedSelftest"), "no gate installedSelftest"),
            "no failed-update gate": (lambda m: m["gates"].pop("failedUpdateRelaunch"), "no gate failedUpdateRelaunch"),
            "a failed failed-update gate": (lambda m: m["gates"].update(failedUpdateRelaunch="failure"),
                                            "gate failedUpdateRelaunch is \"failure\""),
            "an extra failed gate": (lambda m: m["gates"].update(inAppUpdate="failure"), "gate inAppUpdate"),
            "upgrade first on another gate": (lambda m: m["gates"].update(upgrade="first"), "gate upgrade is"),
            "an extra ISCC define": (lambda m: m["installer"]["isccDefines"].append("PTBTestFailInstall"), "isccDefines"),
            "a missing ISCC define": (lambda m: m["installer"]["isccDefines"].remove("OutDir"), "isccDefines"),
            "another installer name": (lambda m: m["installer"].update(name="PokeTokenBar-Setup-2.5.639-win-x64.exe"),
                                       "installer.name"),
            "the setup's file version": (lambda m: m["installer"].update(fileVersion="2.5.639.0"), "installer.fileVersion"),
            "the app's version file": (lambda m: m["app"].update(versionFile="2.5.639"), "app.versionFile"),
            "the uninstall version": (lambda m: m["app"].update(uninstallDisplayVersion=""), "uninstallDisplayVersion"),
            "another run's artifact": (lambda m: m.update(runId=self.app + 1), "windows-release.json runId"),
            "schema 2": (lambda m: m.update(schema=2), "windows-release.json schema"),
            "a boolean schema": (lambda m: m.update(schema=True), "windows-release.json schema"),
            "no workflow sha": (lambda m: m.pop("workflowSha"), "workflowSha"),
            "no run attempt": (lambda m: m.pop("runAttempt"), "runAttempt (the run's attempt) is null"),
            "an empty runner image": (lambda m: m.update(runnerImage=""), "runnerImage is \"\", expected text"),
            "no swift version": (lambda m: m.pop("swift"), "swift is null, expected text"),
        }
        for name, (mutate, expected) in cases.items():
            with self.subTest(name):
                self.assertIn(expected, self.mismatch(mutate_release=mutate))

    def test_tests_manifest_mismatches_are_refused(self):
        cases = {
            "too few tests": (lambda m: m.update(executed=2399), "executed is 2399"),
            "a failure": (lambda m: m.update(failures=1), "failures is 1"),
            "another sha": (lambda m: m.update(sha=OTHER_SHA), "windows-tests.json sha"),
            "another version": (lambda m: m.update(version="2.5.639"), "windows-tests.json version"),
            "a string count": (lambda m: m.update(executed="2431"), "executed is \"2431\""),
            "a negative skip count": (lambda m: m.update(skipped=-1), "skipped is -1, expected a count"),
            "no skip count": (lambda m: m.pop("skipped"), "skipped is null, expected a count"),
        }
        for name, (mutate, expected) in cases.items():
            with self.subTest(name):
                self.assertIn(expected, self.mismatch(mutate_tests=mutate))

    def test_upgrade_from_release_may_be_first_only_before_any_windows_release(self):
        first = lambda m: m["gates"].update(upgradeFromRelease="first")
        release = release_manifest(self.app)
        first(release)
        self.set_artifacts(release, tests_manifest())
        self.gh.add_release("v2.5.634", False, assets=[{"name": "PokeTokenBar.zip"}])
        self.assertExit(0, self.collect())
        self.gh.add_release("v2.5.639", False, assets=[{"name": "PokeTokenBar.zip"},
                                                       {"name": "PokeTokenBar-Setup-2.5.639-win-x64.exe"}])
        self.assertIn("upgradeFromRelease is first, but v2.5.639 has a Windows installer", self.mismatch(first))

    def test_first_is_refused_when_the_releases_cannot_be_read(self):
        release = release_manifest(self.app)
        release["gates"]["upgradeFromRelease"] = "first"
        self.set_artifacts(release, tests_manifest())
        self.gh.on(lambda argv: argv[1] == "api", lambda argv: tr.Result(1, "", "HTTP 502\n"))
        self.assertExit(4, self.collect())
        self.assertIn("cannot check that no earlier Windows release exists", self.err)

    def test_a_manifest_that_is_not_json(self):
        self.gh.artifacts[(self.tests, "windows-tests")] = {"windows-tests.json": b"{not json"}
        self.assertExit(4, self.collect())
        self.assertIn("cannot read windows-tests.json", self.err)

    def test_a_manifest_that_is_not_an_object(self):
        self.gh.artifacts[(self.tests, "windows-tests")] = {"windows-tests.json": b"[]"}
        self.assertExit(4, self.collect())
        self.assertIn("windows-tests.json is not a JSON object", self.err)

    def test_a_hash_or_size_mismatch_after_the_download(self):
        tampered = INSTALLER_BYTES[:-1] + b"X"
        self.assertIn("installer.sha256 (the downloaded file's)", self.mismatch(installer=tampered))
        self.assertIn("installer.size (the downloaded file's)", self.mismatch(installer=INSTALLER_BYTES + b"!"))

    def test_an_extra_file_in_the_artifact(self):
        err = self.mismatch(extra={"PokeTokenBar-Setup-2.5.639-win-x64.exe": b"old"})
        self.assertIn("the artifact windows-release holds", err)

    def test_a_missing_artifact(self):
        del self.gh.artifacts[(self.tests, "windows-tests")]
        self.assertExit(4, self.collect())
        self.assertIn("could not download windows-tests", self.err)

    def test_an_earlier_download_is_replaced(self):
        stale = self.tmp / "out/windows-release"
        stale.mkdir(parents=True)
        (stale / "PokeTokenBar-Setup-2.5.639-win-x64.exe").write_bytes(b"old")
        self.assertExit(0, self.collect())
        self.assertEqual(sorted(["windows-release.json", INSTALLER]), sorted(p.name for p in stale.iterdir()))

    def test_dry_run_reads_once_and_downloads_nothing(self):
        self.assertExit(0, self.collect("--dry-run"))
        self.assertEqual(["gh run view", "gh run view"], self.gh.compact())
        self.assertIn("DRY-RUN (not run): gh run download %d --name windows-release" % self.app, self.err)
        self.assertFalse((self.tmp / "out").exists())
        self.assertEqual([], self.clock.sleeps)


# ── publish ────────────────────────────────────────────────────────────────────────────────────────────────────

HAPPY = ["gh api releases", "git ls-remote", "gh api releases/latest",           # before create
         "gh release create", "gh api releases", "git ls-remote",               # the draft, by id
         "gh api releases/latest", "gh api releases", "gh release edit",         # right before the edit
         "gh api releases/latest", "git ls-remote"]                              # after publishing


class PublishTests(HelperTest):
    def setUp(self):
        super().setUp()
        self.zip = self.tmp / "build/PokeTokenBar.zip"
        self.installer = self.tmp / "out/windows-release" / INSTALLER
        self.manifest = self.tmp / "out/windows-release/windows-release.json"
        self.notes = self.tmp / "build/release-notes.md"
        notes = "## New\n\nThings.\n\nWindows installer SHA-256: `%s`\n" % sha256(INSTALLER_BYTES)
        for path, data in ((self.zip, ZIP_BYTES), (self.installer, INSTALLER_BYTES), (self.notes, notes.encode()),
                           (self.manifest, json.dumps(release_manifest(12345)).encode())):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.gh.add_release("v2.5.634", False, target="8f050c929cf1a3d5f081761b67c54f25ec0a8854",
                            assets=[{"name": "PokeTokenBar.zip", "size": 1, "state": "uploaded", "digest": "sha256:" + "0" * 64}])

    def publish(self, *extra, zip_path=None, installer=None):
        return self.run_helper("publish", "--sha", SHA, "--version", V, "--zip", str(zip_path or self.zip),
                               "--installer", str(installer or self.installer), "--notes", str(self.notes), *extra)

    def on_list(self, n, effect):
        """Run `effect(fake)` before the n-th read of the release list (1 = the check before create)."""
        self.gh.on(nth(n, is_call("api", LIST)), lambda argv: (effect(self.gh), None)[1])

    def corrupt_draft(self, change):
        """Right after create, change this run's draft (a digest GitHub computed differently, say)."""
        self.on_list(2, lambda gh: change(gh.tagged(TAG)[0]))

    def other_draft(self, gh):
        """Another session creates its own draft vV (gh create --draft does not look for one)."""
        return gh.add_release(TAG, True, assets=[{"name": "PokeTokenBar.zip", "size": 9, "state": "uploaded",
                                                  "digest": "sha256:" + "9" * 64}])

    def assertNothingPublished(self):
        self.assertTrue(all(release["draft"] for release in self.gh.tagged(TAG)))
        self.assertNotIn(TAG, self.gh.tags)
        self.assertEqual("v2.5.634", self.gh.latest)
        self.assertEqual([], self.gh.calls_of("release", "edit"))

    def assertTouchedNothing(self):
        self.assertEqual([], self.gh.calls_of("release", "edit"))
        self.assertEqual([], self.gh.calls_of("release", "delete"))

    def test_the_happy_path_in_its_exact_order(self):
        self.assertExit(0, self.publish())
        self.assertEqual(HAPPY, self.gh.compact())
        self.assertEqual(["gh", "release", "create", TAG, str(self.zip), str(self.installer), "--draft", "--target", SHA,
                          "--title", TAG, "--notes-file", str(self.notes)] + REPO_ARGS,
                         self.gh.calls_of("release", "create")[0])
        self.assertEqual(["gh", "api", LIST], self.gh.calls[0])
        self.assertEqual(["gh", "release", "edit", TAG, "--draft=false", "--latest"] + REPO_ARGS,
                         self.gh.calls_of("release", "edit")[0])
        self.assertEqual(["git", "ls-remote", "https://github.com/likelion-campus/PokeTokenBar.git", "refs/tags/" + TAG],
                         self.gh.calls[1])
        release = self.gh.find(TAG)
        self.assertEqual(TAG, self.gh.latest)
        self.assertEqual(SHA, self.gh.tags[TAG])
        self.assertFalse(release["draft"])
        self.assertEqual({"PokeTokenBar.zip", INSTALLER}, {asset["name"] for asset in release["assets"]})
        self.assertIn("(id %d)" % release["id"], self.err)
        self.assertEqual("", self.out)

    # before create

    def test_a_public_release_is_refused_before_create_with_its_own_exit(self):
        self.gh.add_release(TAG, False)
        self.assertExit(7, self.publish())
        self.assertEqual(["gh api releases"], self.gh.compact())
        self.assertIn("already public", self.err)

    def test_a_leftover_draft_is_reported_not_reused_or_deleted(self):
        self.gh.add_release(TAG, True)
        self.assertExit(5, self.publish())
        self.assertEqual(["gh api releases"], self.gh.compact())
        self.assertIn("draft %s exists already" % TAG, self.err)
        self.assertTrue(self.gh.find(TAG)["draft"])

    def test_an_existing_tag_is_refused_before_create(self):
        self.gh.tags[TAG] = OTHER_SHA
        self.assertExit(5, self.publish())
        self.assertEqual(["gh api releases", "git ls-remote"], self.gh.compact())
        self.assertIn("would ignore --target", self.err)

    def test_a_newer_latest_is_refused_before_create(self):
        self.gh.add_release("v2.5.641", False)
        self.assertExit(5, self.publish())
        self.assertEqual(["gh api releases", "git ls-remote", "gh api releases/latest"], self.gh.compact())
        self.assertIn("releases/latest is v2.5.641, which is newer than %s" % TAG, self.err)

    def test_an_older_or_missing_latest_lets_create_go_on(self):
        self.gh.releases, self.gh.latest = [], None
        self.assertExit(0, self.publish())
        self.assertEqual(HAPPY, self.gh.compact())

    def test_wrong_local_files_are_refused_before_any_call(self):
        wrong_zip = self.tmp / "build/Other.zip"
        wrong_zip.write_bytes(ZIP_BYTES)
        old = self.tmp / "PokeTokenBar-Setup-2.5.639-win-x64.exe"
        old.write_bytes(INSTALLER_BYTES)
        for kwargs, expected in (({"zip_path": wrong_zip}, "expected PokeTokenBar.zip"),
                                 ({"installer": old}, "expected " + INSTALLER),
                                 ({"zip_path": self.tmp / "missing/PokeTokenBar.zip"}, "missing or empty")):
            with self.subTest(expected):
                self.assertExit(5, self.publish(**kwargs))
                self.assertIn(expected, self.err)
        self.assertEqual([], self.gh.calls)

    def test_the_installer_must_be_the_one_collect_checked_for_this_commit(self):
        def manifest(change):
            data = release_manifest(12345)
            change(data)
            self.manifest.write_text(json.dumps(data))
        cases = {
            "another commit": (lambda m: m.update(sha=OTHER_SHA), "windows-release.json sha"),
            "another version": (lambda m: m.update(version="2.5.639"), "windows-release.json version"),
            "another size": (lambda m: m["installer"].update(size=1), "installer.size (the file's)"),
            "another hash": (lambda m: m["installer"].update(sha256="e" * 64), "installer.sha256 (the file's)"),
            "another name": (lambda m: m["installer"].update(name="x.exe"), "installer.name"),
        }
        for name, (change, expected) in cases.items():
            with self.subTest(name):
                manifest(change)
                self.assertExit(5, self.publish())
                self.assertIn(expected, self.err)
        self.manifest.unlink()
        self.assertExit(5, self.publish())
        self.assertIn("cannot read windows-release.json", self.err)
        self.assertEqual([], self.gh.calls)

    def test_the_notes_must_be_filled_and_carry_the_installer_hash(self):
        for text, expected in (("  \n", "missing or empty"),
                               ("SHA-256: `%s` {{VERSION}}\n" % sha256(INSTALLER_BYTES), "{{…}} token"),
                               ("## New\n\nNo hash here.\n", "do not carry the installer's SHA-256")):
            with self.subTest(expected):
                self.notes.write_text(text)
                self.assertExit(5, self.publish())
                self.assertIn(expected, self.err)
        self.assertEqual([], self.gh.calls)

    def test_a_failed_existence_check_creates_nothing(self):
        self.gh.on(nth(1, is_call("api", LIST)), lambda argv: tr.Result(1, "", "HTTP 502\n"))
        self.assertExit(5, self.publish())
        self.assertEqual(["gh api releases"], self.gh.compact())

    # the draft

    def test_an_upload_failure_deletes_the_draft(self):
        self.gh.upload_fails_after = 1
        self.assertExit(5, self.publish())
        self.assertEqual(HAPPY[:4] + ["gh api releases", "gh release delete"], self.gh.compact())
        self.assertEqual([], self.gh.tagged(TAG))
        self.assertNothingPublished()
        self.assertIn("The draft this run created (id", self.err)

    def test_a_failed_create_that_left_nothing_deletes_nothing(self):
        self.gh.on(is_call("release", "create"), lambda argv: tr.Result(1, "", "HTTP 422\n"))
        self.assertExit(5, self.publish())
        self.assertEqual([], self.gh.calls_of("release", "delete"))
        self.assertIn("No release %s exists" % TAG, self.err)

    def test_draft_mismatches_delete_the_draft(self):
        def extra_asset(release):
            release["assets"].append({"name": "PokeTokenBar-Setup-2.5.639-win-x64.exe", "size": 3, "state": "uploaded",
                                      "digest": "sha256:" + sha256(b"old")})

        cases = {
            "a digest mismatch": (lambda r: r["assets"][1].update(digest="sha256:" + "f" * 64), "has digest sha256:fff"),
            "no digest on a draft": (lambda r: r["assets"][1].update(digest=None), "has digest None"),
            "an extra asset": (extra_asset, "the assets are"),
            "a missing asset": (lambda r: r["assets"].pop(0), "the assets are"),
            "an asset still uploading": (lambda r: r["assets"][0].update(state="starter"), "is starter, not uploaded"),
            "a size mismatch": (lambda r: r["assets"][0].update(size=1), "is 1 bytes on GitHub"),
            "another target": (lambda r: r.update(target=OTHER_SHA), "the draft targets " + OTHER_SHA),
        }
        for name, (change, expected) in cases.items():
            with self.subTest(name):
                self.setUp()
                self.corrupt_draft(change)
                self.assertExit(5, self.publish())
                self.assertIn(expected, self.err)
                self.assertEqual(1, len(self.gh.calls_of("release", "delete")))
                self.assertEqual([], self.gh.tagged(TAG))
                self.assertNothingPublished()

    def test_a_draft_that_reads_public_right_after_create(self):
        # Someone published it at once (or GitHub made it public): the draft check names it, and nothing is deleted.
        self.corrupt_draft(lambda r: r.update(draft=False))
        self.assertExit(6, self.publish())
        self.assertIn("is not a draft", self.err)
        self.assertIn("never sent its publish request, so someone else published", self.err)
        self.assertTouchedNothing()

    def test_a_tag_on_a_draft_stops_the_release(self):
        # Assumption A1 broken: GitHub made the tag when the draft was created.
        self.gh.on(is_call("release", "create"), lambda argv: self.gh.tags.update({TAG: SHA}))
        self.assertExit(5, self.publish())
        self.assertIn("exists (at %s) while the release is a draft" % SHA, self.err)
        self.assertEqual([], self.gh.tagged(TAG))
        self.assertEqual([], self.gh.calls_of("release", "edit"))

    def test_a_draft_missing_from_the_list_right_after_create(self):
        self.gh.on(nth(2, is_call("api", LIST)), lambda argv: ok(json.dumps([])))
        self.assertExit(5, self.publish())
        self.assertIn("Right after create: 0 releases carry the tag", self.err)
        self.assertTouchedNothing()

    # two sessions releasing the same version

    def test_another_draft_made_before_ours_stops_without_editing_or_deleting(self):
        for pick in ("first", "last"):
            with self.subTest(pick):
                self.setUp()
                self.gh.pick = pick
                self.gh.on(is_call("release", "create"), lambda argv: (self.other_draft(self.gh), None)[1])
                self.assertExit(5, self.publish())
                self.assertIn("Right after create: 2 releases carry the tag %s" % TAG, self.err)
                self.assertIn("none of them is public", self.err)
                self.assertTouchedNothing()
                self.assertEqual(2, len(self.gh.tagged(TAG)))
                self.assertNothingPublished()

    def test_another_draft_made_after_ours_stops_before_the_edit(self):
        for pick in ("first", "last"):
            with self.subTest(pick):
                self.setUp()
                self.gh.pick = pick
                self.gh.on(nth(2, is_call("api", LATEST)), lambda argv: (self.other_draft(self.gh), None)[1])
                self.assertExit(5, self.publish())
                self.assertIn("Before publishing: 2 releases carry the tag %s" % TAG, self.err)
                self.assertTouchedNothing()
                self.assertEqual(2, len(self.gh.tagged(TAG)))
                self.assertNothingPublished()

    def test_another_draft_at_cleanup_is_not_deleted(self):
        for pick in ("first", "last"):
            with self.subTest(pick):
                self.setUp()
                self.gh.pick = pick
                self.corrupt_draft(lambda r: r["assets"][1].update(digest=None))
                self.on_list(3, self.other_draft)
                self.assertExit(5, self.publish())
                self.assertIn("At cleanup: 2 releases carry the tag %s" % TAG, self.err)
                self.assertTouchedNothing()
                self.assertEqual(2, len(self.gh.tagged(TAG)))

    def test_another_session_publishing_its_own_vV_meanwhile(self):
        def theirs_public(gh):
            gh.add_release(TAG, False, target=OTHER_SHA)
        self.on_list(3, theirs_public)
        self.assertExit(6, self.publish())
        self.assertIn("a public release carries the tag", self.err)
        self.assertTouchedNothing()

    def test_someone_publishing_this_runs_draft_before_the_edit(self):
        self.on_list(3, lambda gh: gh.tagged(TAG)[0].update(draft=False))
        self.assertExit(6, self.publish())
        self.assertIn("before this run sent its publish request, its draft %s" % TAG, self.err)
        self.assertTouchedNothing()

    def test_this_runs_draft_deleted_by_someone_before_the_edit(self):
        self.on_list(3, lambda gh: gh.releases.remove(gh.tagged(TAG)[0]))
        self.assertExit(5, self.publish())
        self.assertIn("Before publishing: 0 releases carry the tag", self.err)
        self.assertTouchedNothing()

    def test_a_newer_release_published_while_waiting_deletes_this_runs_draft(self):
        self.gh.on(nth(2, is_call("api", LATEST)), lambda argv: (self.gh.add_release("v2.5.641", False), None)[1])
        self.assertExit(5, self.publish())
        self.assertIn("releases/latest became v2.5.641, newer than %s" % TAG, self.err)
        self.assertEqual([], self.gh.calls_of("release", "edit"))
        self.assertEqual(1, len(self.gh.calls_of("release", "delete")))
        self.assertEqual([], self.gh.tagged(TAG))
        self.assertEqual("v2.5.641", self.gh.latest)

    # cleanup

    def test_a_release_that_reads_published_at_cleanup_is_not_deleted(self):
        self.corrupt_draft(lambda r: r["assets"][1].update(digest="sha256:" + "f" * 64))
        self.on_list(3, lambda gh: gh.tagged(TAG)[0].update(draft=False))
        self.assertExit(6, self.publish())
        self.assertEqual([], self.gh.calls_of("release", "delete"))
        self.assertEqual(1, len(self.gh.tagged(TAG)))
        self.assertIn("never sent its publish request, so someone else published", self.err)

    def test_a_cleanup_read_that_fails_deletes_nothing(self):
        self.corrupt_draft(lambda r: r["assets"][1].update(digest=None))
        self.gh.on(nth(3, is_call("api", LIST)), lambda argv: tr.Result(1, "", "HTTP 502\n"))
        self.assertExit(6, self.publish())
        self.assertEqual([], self.gh.calls_of("release", "delete"))
        self.assertIn("nothing was deleted", self.err)

    def test_a_failed_delete_says_the_draft_remains(self):
        self.gh.upload_fails_after = 0
        self.gh.on(is_call("release", "delete"), lambda argv: tr.Result(1, "", "HTTP 500\n"))
        self.assertExit(5, self.publish())
        self.assertIn("delete the draft %s" % TAG, self.err)
        self.assertNothingPublished()

    def test_a_failed_edit_that_left_a_draft_deletes_it(self):
        self.gh.on(is_call("release", "edit"), lambda argv: tr.Result(1, "", "HTTP 422\n"))
        self.assertExit(5, self.publish())
        self.assertEqual(["gh release edit", "gh api releases", "gh release delete"], self.gh.compact()[8:])
        self.assertEqual([], self.gh.tagged(TAG))

    def test_a_failed_edit_that_published_anyway_deletes_nothing(self):
        def publishes_then_fails(argv):
            self.gh._release_edit(argv[3:-2])
            return tr.Result(1, "", "connection reset\n")
        self.gh.on(is_call("release", "edit"), publishes_then_fails)
        self.assertExit(6, self.publish())
        self.assertEqual([], self.gh.calls_of("release", "delete"))
        self.assertFalse(self.gh.find(TAG)["draft"])
        self.assertIn("this run sent its publish request (gh release edit), which failed", self.err)
        self.assertNotIn("someone else", self.err)

    def test_a_failed_read_after_create_deletes_the_draft(self):
        self.gh.on(nth(2, is_call("api", LIST)), lambda argv: tr.Result(1, "", "HTTP 502\n"))
        self.assertExit(5, self.publish())
        self.assertEqual(["gh release create", "gh api releases", "gh api releases", "gh release delete"],
                         self.gh.compact()[3:])
        self.assertEqual([], self.gh.tagged(TAG))
        self.assertNothingPublished()

    def test_a_failed_tag_read_on_the_draft_deletes_the_draft(self):
        self.gh.on(lambda argv: argv[0] == "git" and self.gh.tagged(TAG),
                   lambda argv: tr.Result(128, "", "fatal: unable to access\n"))
        self.assertExit(5, self.publish())
        self.assertIn("unable to access", self.err)
        self.assertEqual([], self.gh.tagged(TAG))

    # interruptions and re-runs

    def interrupt(self, how):
        def effect(argv):
            if how == "ctrl-c":
                raise KeyboardInterrupt
            os.kill(os.getpid(), getattr(signal, how))
        return effect

    def test_an_interruption_before_publishing_deletes_the_draft(self):
        for how in ("ctrl-c", "SIGTERM", "SIGHUP"):
            with self.subTest(how):
                self.setUp()
                self.gh.on(lambda argv: argv[0] == "git" and self.gh.tagged(TAG), self.interrupt(how))
                self.assertExit(5, self.publish())
                self.assertIn("interrupted", self.err)
                self.assertEqual([], self.gh.tagged(TAG))
                self.assertNothingPublished()

    def test_an_interruption_before_create_says_nothing_was_created(self):
        self.gh.on(nth(1, is_call("api", LIST)), self.interrupt("SIGTERM"))
        self.assertExit(5, self.publish())
        self.assertIn("interrupted; nothing was created", self.err)
        self.assertEqual([], self.gh.calls_of("release", "create"))

    def test_main_restores_the_signal_handlers(self):
        self.publish()
        self.assertEqual((_not_taken, _not_taken), (signal.getsignal(signal.SIGTERM), signal.getsignal(signal.SIGHUP)))

    def test_a_second_signal_during_cleanup_says_a_draft_may_remain(self):
        self.gh.on(lambda argv: argv[0] == "git" and self.gh.tagged(TAG), self.interrupt("SIGTERM"))
        self.gh.on(nth(3, is_call("api", LIST)), self.interrupt("SIGHUP"))
        self.assertExit(5, self.publish())
        self.assertIn("a draft this run created may remain", self.err)
        self.assertEqual([], self.gh.calls_of("release", "delete"))

    def test_a_second_signal_after_the_edit_was_sent_exits_6(self):
        self.gh.on(is_call("release", "edit"), self.interrupt("SIGTERM"))
        self.gh.on(nth(4, is_call("api", LIST)), self.interrupt("SIGTERM"))
        self.assertExit(6, self.publish())
        self.assertIn("this run had sent its publish request, so the release may be public", self.err)

    def test_an_interruption_after_publishing_exits_6(self):
        self.gh.on(is_call("api", LATEST), lambda argv: (self.gh.latest == TAG and self.interrupt("ctrl-c")(argv)) or None)
        self.assertExit(6, self.publish())
        self.assertIn("interrupted while checking", self.err)
        self.assertEqual([], self.gh.calls_of("release", "delete"))
        self.assertFalse(self.gh.find(TAG)["draft"])

    def test_a_rerun_after_an_interruption_that_left_a_draft_is_refused(self):
        self.gh.on(nth(1, is_call("release", "delete")), lambda argv: tr.Result(1, "", "killed\n"))
        self.gh.upload_fails_after = 1
        self.assertExit(5, self.publish())
        self.gh.hooks, self.gh.upload_fails_after, self.gh.calls = [], None, []
        self.assertExit(5, self.publish())
        self.assertEqual(["gh api releases"], self.gh.compact())
        self.assertIn("draft %s exists already" % TAG, self.err)

    def test_a_rerun_after_a_publish_is_refused_as_already_public(self):
        self.assertExit(0, self.publish())
        self.gh.calls = []
        self.assertExit(7, self.publish())
        self.assertEqual(["gh api releases"], self.gh.compact())

    # after publishing

    def test_latest_not_this_release_after_publishing(self):
        self.gh.on(is_call("release", "edit"),
                   lambda argv: (self.gh._release_edit(argv[3:-2]), setattr(self.gh, "latest", "v2.5.634"))[0])
        self.assertExit(6, self.publish())
        self.assertIn("releases/latest is v2.5.634 (id", self.err)
        self.assertEqual([], self.gh.calls_of("release", "delete"))
        self.assertFalse(self.gh.find(TAG)["draft"])
        self.assertEqual(3, self.gh.compact()[9:].count("gh api releases/latest"))
        self.assertEqual([10, 10], self.clock.sleeps)

    def test_latest_must_be_this_runs_release_not_just_its_tag(self):
        # Another session's release vV became latest (same tag, its own zip); this run's edit did not publish.
        def theirs_instead(argv):
            self.gh.add_release(TAG, False, assets=[dict(asset) for asset in self.gh.tagged(TAG)[0]["assets"]])
            self.gh.tagged(TAG)[1]["assets"][0]["digest"] = "sha256:" + "9" * 64
            return ok()
        self.gh.on(is_call("release", "edit"), theirs_instead)
        self.assertExit(6, self.publish())
        self.assertIn("releases/latest is %s (id %d), not this run's %s (id %d)" % (
            TAG, self.gh.tagged(TAG)[1]["id"], TAG, self.gh.tagged(TAG)[0]["id"]), self.err)
        self.assertEqual([], self.gh.calls_of("release", "delete"))

    def test_latest_shows_after_a_moment(self):
        def stale(argv):
            if self.gh.latest == TAG and not self.clock.sleeps:
                return ok(json.dumps(self.gh.rest(self.gh.find("v2.5.634"))))
            return None
        self.gh.on(is_call("api", LATEST), stale)
        self.assertExit(0, self.publish())
        self.assertEqual([10], self.clock.sleeps)

    def test_published_asset_or_tag_mismatches_exit_6_without_deleting(self):
        def latest_digest(argv):
            if self.gh.latest != TAG:
                return None
            body = self.gh.rest(self.gh.find(TAG))
            body["assets"][0]["digest"] = "sha256:" + "e" * 64
            return ok(json.dumps(body))

        cases = {
            "a digest": (lambda: self.gh.on(is_call("api", LATEST), latest_digest), "has digest sha256:eee"),
            "the tag": (lambda: self.gh.on(is_call("release", "edit"), lambda argv: self.gh.tags.update({TAG: OTHER_SHA})),
                        "tag %s points at %s" % (TAG, OTHER_SHA)),
            "the target": (lambda: self.gh.on(is_call("release", "edit"),
                                              lambda argv: self.gh.find(TAG).update(target=OTHER_SHA)),
                           "releases/latest targets " + OTHER_SHA),
        }
        for name, (inject, expected) in cases.items():
            with self.subTest(name):
                self.setUp()
                inject()
                self.assertExit(6, self.publish())
                self.assertIn(expected, self.err)
                self.assertEqual([], self.gh.calls_of("release", "delete"))

    def test_latest_that_cannot_be_read_exits_6(self):
        self.gh.on(is_call("api", LATEST),
                   lambda argv: tr.Result(1, "", "HTTP 502\n") if self.gh.latest == TAG else None)
        self.assertExit(6, self.publish())
        self.assertEqual(3, self.gh.compact()[9:].count("gh api releases/latest"))
        self.assertEqual([], self.gh.calls_of("release", "delete"))

    def test_dry_run_reads_and_prints_every_command(self):
        self.assertExit(0, self.publish("--dry-run"))
        self.assertEqual(["gh api releases", "git ls-remote", "gh api releases/latest"], self.gh.compact())
        planned = [line[len("DRY-RUN (not run): "):].split("    #")[0] for line in self.err.splitlines()
                   if line.startswith("DRY-RUN (not run): ")]
        self.assertEqual(
            ["gh release create %s %s %s --draft --target %s --title %s --notes-file %s --repo likelion-campus/PokeTokenBar"
             % (TAG, self.zip, self.installer, SHA, TAG, self.notes),
             "gh api " + LIST, "git ls-remote https://github.com/likelion-campus/PokeTokenBar.git refs/tags/" + TAG,
             "gh api " + LATEST, "gh api " + LIST,
             "gh release edit %s --draft=false --latest --repo likelion-campus/PokeTokenBar" % TAG,
             "gh api " + LATEST, "git ls-remote https://github.com/likelion-campus/PokeTokenBar.git refs/tags/" + TAG,
             "gh api " + LIST, "gh release delete %s --yes --repo likelion-campus/PokeTokenBar" % TAG],
            [line.replace("'", "") for line in planned])
        self.assertEqual([], self.gh.tagged(TAG))
        self.assertIn("sha256:" + sha256(INSTALLER_BYTES), self.err)


# ── smoke ──────────────────────────────────────────────────────────────────────────────────────────────────────


class SmokeTests(HelperTest):
    def test_no_smoke_workflow_yet(self):
        self.assertExit(0, self.run_helper("smoke", "--version", V))
        self.assertEqual("no smoke workflow yet\n", self.out)
        self.assertEqual([], self.gh.calls_of("workflow", "run"))
        self.assertEqual(["gh", "api", API + "contents/.github/workflows/windows-release-smoke.yml?ref=main"],
                         self.gh.calls[0])

    def test_dispatches_and_prints_the_run_url(self):
        self.gh.workflow_files.add(("main", "windows-release-smoke.yml"))
        earlier = self.gh.add_run("windows-release-smoke.yml", title="windows-release-smoke")
        self.assertExit(0, self.run_helper("smoke", "--version", V))
        self.assertEqual([["gh", "workflow", "run", "windows-release-smoke.yml", "--ref", "main", "-f", "version=" + V]
                          + REPO_ARGS], self.gh.calls_of("workflow", "run"))
        run_id = self.gh.runs["windows-release-smoke.yml"][-1]["databaseId"]
        self.assertNotEqual(earlier, run_id)
        self.assertEqual("https://github.com/likelion-campus/PokeTokenBar/actions/runs/%d\n" % run_id, self.out)

    def test_a_smoke_run_that_does_not_show_prints_the_workflow_page(self):
        self.gh.workflow_files.add(("main", "windows-release-smoke.yml"))
        self.gh.appear_after = None
        self.assertExit(0, self.run_helper("smoke", "--version", V))
        self.assertEqual("https://github.com/likelion-campus/PokeTokenBar/actions/workflows/windows-release-smoke.yml\n",
                         self.out)

    def test_a_failed_smoke_dispatch_or_check_exits_1(self):
        self.gh.workflow_files.add(("main", "windows-release-smoke.yml"))
        self.gh.on(is_call("workflow", "run"), lambda argv: tr.Result(1, "", "HTTP 422\n"))
        self.assertExit(1, self.run_helper("smoke", "--version", V))
        self.gh = FakeGitHub()
        self.gh.on(lambda argv: argv[1] == "api", lambda argv: tr.Result(1, "", "HTTP 401: Bad credentials\n"))
        self.assertExit(1, self.run_helper("smoke", "--version", V))
        self.assertIn("Bad credentials", self.err)

    def test_a_branch_ref_is_quoted(self):
        self.gh.workflow_files.add(("ci/x", "windows-release-smoke.yml"))
        self.assertExit(0, self.run_helper("smoke", "--version", V, "--ref", "ci/x", "--dry-run"))
        self.assertTrue(self.gh.calls[0][2].endswith("?ref=ci%2Fx"))
        self.assertEqual([], self.gh.calls_of("workflow", "run"))
        self.assertIn("DRY-RUN (not run): gh workflow run windows-release-smoke.yml --ref ci/x", self.err)


# ── call sites ─────────────────────────────────────────────────────────────────────────────────────────────────


class GateMapTests(unittest.TestCase):
    """REQUIRED_GATES and the manifest's gate map (release-manifest.ps1) name the same gates."""

    def test_required_gates_are_the_manifest_gate_map(self):
        text = (ROOT / "scripts/windows/release-manifest.ps1").read_text()
        block = re.search(r"\$gateSteps = \[ordered\]@\{(.*?)\n\}", text, re.S)
        self.assertIsNotNone(block)
        mapped = re.findall(r"^\s*(\w+)\s*=\s*'([\w-]+)'\s*$", block.group(1), re.M)
        self.assertEqual(list(tr.REQUIRED_GATES), [name for name, _ in mapped])
        self.assertIn(("failedUpdateRelaunch", "failed-update-relaunch"), mapped)
        workflow = (ROOT / ".github/workflows/windows-app.yml").read_text()
        for _, step in mapped:
            self.assertIn("id: " + step + "\n", workflow, step)


class CallSiteScanTests(unittest.TestCase):
    """What the module can call, read from its own source."""

    source = SCRIPT.read_text()
    tree = ast.parse(source)

    def strings(self):
        """Every string literal except docstrings."""
        docstrings = {id(node.body[0].value) for node in ast.walk(self.tree)
                      if isinstance(node, (ast.Module, ast.FunctionDef, ast.ClassDef)) and node.body
                      and isinstance(node.body[0], ast.Expr) and isinstance(node.body[0].value, ast.Constant)}
        return [node.value for node in ast.walk(self.tree) if isinstance(node, ast.Constant)
                and isinstance(node.value, str) and id(node) not in docstrings]

    def functions(self):
        return [node for node in ast.walk(self.tree) if isinstance(node, ast.FunctionDef)]

    def enclosing(self, target):
        inner = [fn for fn in self.functions() if any(node is target for node in ast.walk(fn))]
        return min(inner, key=lambda fn: fn.end_lineno - fn.lineno)

    def gh_calls(self, method):
        return [node for node in ast.walk(self.tree) if isinstance(node, ast.Call)
                and isinstance(node.func, ast.Attribute) and node.func.attr == method]

    def constant_args(self, call):
        return [arg.value for arg in call.args if isinstance(arg, ast.Constant)]

    def test_no_push_no_tag_writes_no_rest_delete(self):
        strings = self.strings()
        for forbidden in ("push", "tag", "--cleanup-tag", "DELETE", "--method", "-X", "-R", "upload", "delete-asset"):
            self.assertNotIn(forbidden, strings)
        for text in strings:
            self.assertNotRegex(text, r"-X\s*DELETE|--method[ =]DELETE|git push|cleanup-tag")

    def test_one_repository_only(self):
        self.assertNotIn("chattymin", self.source)
        self.assertEqual(1, self.source.count('"likelion-campus/PokeTokenBar"'))
        for text in self.strings():
            if text != "likelion-campus/PokeTokenBar":
                self.assertNotIn("likelion-campus", text)
                self.assertNotIn("/PokeTokenBar", text)
            if "github.com" in text:
                self.assertEqual("https://github.com/", text)
        self.assertEqual(1, self.strings().count("--repo"))
        self.assertEqual(1, self.strings().count("repos/"))

    def test_gh_release_subcommands_are_create_edit_delete(self):
        verbs = set()
        for node in ast.walk(self.tree):
            items = node.args if isinstance(node, ast.Call) else node.elts if isinstance(node, ast.Tuple) else []
            words = [item.value for item in items[:2] if isinstance(item, ast.Constant)]
            if words[:1] == ["release"]:
                verbs.add(words[1])
        self.assertEqual({"create", "edit", "delete"}, verbs, "no gh release lookup by tag is read for a check")

    def test_release_delete_only_right_after_a_fresh_read_by_id(self):
        deletes = [call for call in self.gh_calls("run") if self.constant_args(call)[:2] == ["release", "delete"]]
        self.assertEqual(1, len(deletes), "exactly one place runs gh release delete")
        delete = deletes[0]
        function = self.enclosing(delete)
        self.assertEqual("remove_own_draft", function.name)
        reads = [node.lineno for node in ast.walk(function) if isinstance(node, ast.Call)
                 and isinstance(node.func, ast.Name) and node.func.id == "tagged_releases"]
        self.assertEqual(1, len(reads))

        def checks(name):
            return [node.lineno for node in ast.walk(function) if isinstance(node, ast.Constant) and node.value == name
                    and reads[0] < node.lineno < delete.lineno]
        self.assertTrue(checks("id"), "the id is compared between the read and the delete")
        self.assertTrue(checks("draft"), "the draft flag is checked between the read and the delete")
        between = [node for node in ast.walk(function) if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                   and node.func.attr in ("run", "api", "api_json", "json", "tag_commit") and reads[0] < node.lineno < delete.lineno]
        self.assertEqual([], between, "no other call between the read and the delete")

    def test_the_edit_is_sent_only_after_the_last_ownership_read(self):
        edits = [call for call in self.gh_calls("run") if any(
            isinstance(arg, ast.Starred) and isinstance(arg.value, ast.Name) and arg.value.id == "publish"
            for arg in call.args)]
        self.assertEqual(1, len(edits))
        publish = self.enclosing(edits[0])
        owned = [node.lineno for node in ast.walk(publish) if isinstance(node, ast.Call)
                 and isinstance(node.func, ast.Name) and node.func.id == "check_still_ours"]
        self.assertEqual(1, len(owned))
        calls_between = [node for node in ast.walk(publish) if isinstance(node, ast.Call)
                         and isinstance(node.func, ast.Attribute) and node.func.attr in ("run", "api", "api_json", "tag_commit")
                         and owned[0] < node.lineno < edits[0].lineno]
        self.assertEqual([], calls_between)

    def test_only_run_process_starts_a_process(self):
        users = {self.enclosing(node).name for node in ast.walk(self.tree)
                 if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id == "subprocess"}
        self.assertEqual({"run_process"}, users)
        for name in ("os", "pty"):
            self.assertNotRegex(self.source, r"^import %s\b|^from %s\b" % (name, name))

    def test_runners_pin_the_repository(self):
        seen = []
        gh = tr.Gh(lambda argv: seen.append(argv) or ok("[]"), False, lambda message: None)
        gh.json("run", "list")
        self.assertEqual(["gh", "run", "list"] + REPO_ARGS, seen[-1])
        gh.api(LATEST)
        self.assertEqual(["gh", "api", LATEST], seen[-1])
        with self.assertRaises(ValueError):
            gh.api("repos/chattymin/PokeTokenBar/releases/latest")
        git = tr.Git(lambda argv: seen.append(argv) or ok(""), False, lambda message: None)
        self.assertIsNone(git.tag_commit(TAG))
        self.assertEqual(["git", "ls-remote", "https://github.com/likelion-campus/PokeTokenBar.git", "refs/tags/" + TAG],
                         seen[-1])

    def test_a_dry_run_never_reaches_a_write(self):
        seen = []
        gh = tr.Gh(lambda argv: seen.append(argv) or ok(), True, lambda message: None)
        for write in (("release", "create", TAG), ("release", "edit", TAG), ("release", "delete", TAG, "--yes"),
                      ("release", "view", TAG), ("workflow", "run", "windows.yml")):
            with self.assertRaises(RuntimeError):
                gh.run(*write)
        self.assertEqual([], seen)

    def test_versions_compare_as_numbers(self):
        self.assertGreater(tr.version_key("v2.5.1000"), tr.version_key("2.5.999"))
        self.assertIsNone(tr.version_key("nightly"))

    def test_run_process_reports_output_and_a_missing_program(self):
        self.assertEqual(tr.Result(3, "out\n", "err\n"), tr.run_process(
            [sys.executable, "-I", "-c", "import sys; print('out'); print('err', file=sys.stderr); sys.exit(3)"]))
        self.assertEqual(127, tr.run_process(["/nonexistent/gh-for-the-test"]).code)

    def test_an_annotated_tag_reads_as_its_commit(self):
        out = "1111111111111111111111111111111111111111\trefs/tags/%s\n%s\trefs/tags/%s^{}\n" % (TAG, SHA, TAG)
        git = tr.Git(lambda argv: ok(out), False, lambda message: None)
        self.assertEqual(SHA, git.tag_commit(TAG))


if __name__ == "__main__":
    unittest.main()
