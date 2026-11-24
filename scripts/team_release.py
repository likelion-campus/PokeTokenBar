#!/usr/bin/env python3
"""The team fork's release writer: the Windows runs, their checks, and the one GitHub release of both systems.

Only this helper writes a release of likelion-campus/PokeTokenBar (stage 8 plan, D2). The Windows workflows keep
`contents: read`. scripts/team-release.sh calls the subcommands in the order of D3:

  start   --sha SHA --version V [--ref main] [--new [failed|windows-app.yml|windows.yml]]...
  collect --sha SHA --version V --out DIR [--timeout-min 170] [--allow-rerun]
  publish --sha SHA --version V --zip PATH --installer PATH --notes PATH
  smoke   --version V [--ref main]

Every subcommand also takes --dry-run: read-only calls run, and every write (a workflow dispatch, a release create,
edit or delete) is printed instead of run. `collect --dry-run` reads each run once and prints what it would download.

Exit codes (team-release.sh relies on them):
  0  done
  1  start or smoke: a gh or git call failed, a dispatched run did not appear within 60 s, or interrupted.
     Nothing was published.
  2  bad arguments
  3  start: the newest release run of a workflow failed, was cancelled or timed out, and --new did not name it.
     Nothing was dispatched.
  4  collect: a run failed, was cancelled or timed out; a run is a re-run (attempt > 1) without --allow-rerun; a
     download failed; a manifest, the artifact's files or the installer hash does not match; or interrupted.
  5  publish: stopped before publishing, and the last read shows no public release vV. This run's own draft was
     deleted, or the message names every draft left and why it was not deleted.
  6  publish: release vV is (or may be) public and something is wrong: a check after publishing failed, the edit
     failed or was interrupted but the release reads public, someone else published this run's draft, or another
     public release shares the tag. Nothing was deleted; the message says what was read and what to check.
  7  publish: release vV was already public before this run. This run created nothing.

Every gh and git call goes through one runner (`run_process`; the tests inject a fake GitHub). `Gh` appends
`--repo likelion-campus/PokeTokenBar`; `Gh.api` only GETs paths under repos/likelion-campus/PokeTokenBar/; `Git` only
runs `git ls-remote` against the fork's URL. Nothing here pushes, creates or deletes a tag, or deletes a published
release.

`publish` identifies its draft by id, not by tag: GitHub allows several drafts with one tag, and gh's
`release edit/delete <tag>` act on whichever one gh's lookup returns. So right after create, right before the edit
and right before a delete it reads every release (`releases?per_page=100`) and goes on only when exactly one release
carries the tag and its id is this run's. The draft's checks read that same list entry, so no check depends on which
draft a by-tag lookup picks.

What this relies on about gh 2.88 and GitHub (risk K3). Read in gh v2.88.1's source and the REST docs on 2026-11-16;
the tests' FakeGitHub encodes the same list:
  A1 `gh release create --draft` makes a draft with the pending tag name and creates no git tag. The tag is created
     at `target_commitish` when the draft is published. (REST docs: target_commitish "determines where the Git tag is
     created from" and is "unused if the Git tag already exists", so publish refuses an existing tag.) The draft
     check also reads the tag: a tag that exists while the release is a draft stops the release.
  A2 `gh release edit/delete <tag>` find a draft by its pending tag (gh FetchRelease: GraphQL `release(tagName:)`,
     then REST by id). With exactly one release carrying the tag, that lookup can only return it.
  A3 An asset uploaded to a draft has `state: uploaded` and `digest: sha256:<hex>`. Seen on every published release;
     on a draft it is unverified. The REST schema says "string or null": a null digest fails the draft check, so
     the draft is deleted and nothing is published.
  A4 `gh release edit <tag> --draft=false --latest` sends one PATCH {draft: false, make_latest: "true"}, the same
     request gh's own create sends when it publishes a release it uploaded as a draft.
  A5 With an explicit --draft, gh does NOT delete the draft when an upload fails (its cleanup runs only for its own
     draft-while-uploading), and does not check for an existing release with that tag. This helper does both.
  A6 The REST list `releases` includes drafts for a token with push access, newest commit first, with each asset's
     digest; `releases/latest` never returns a draft or a prerelease.
"""
import argparse
import collections
import hashlib
import json
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

REPO = "likelion-campus/PokeTokenBar"
API = "repos/" + REPO + "/"
WEB = "https://github.com/" + REPO
GIT_URL = WEB + ".git"
ROOT = Path(__file__).resolve().parents[1]

Workflow = collections.namedtuple("Workflow", "file name key artifact manifest")
WORKFLOWS = (
    Workflow("windows-app.yml", "windows-app", "WINDOWS_APP_RUN", "windows-release", "windows-release.json"),
    Workflow("windows.yml", "windows", "WINDOWS_TESTS_RUN", "windows-tests", "windows-tests.json"),
)
SMOKE_WORKFLOW = "windows-release-smoke.yml"

# The gate steps every release-mode windows-app run must report. Tasks 5 and 6 add theirs in the same PR as the step.
REQUIRED_GATES = ("bundleSelftest", "install", "upgrade", "installedSelftest", "idle", "uninstall", "upgradeFromRelease",
                  "failedUpdateRelaunch", "inAppUpdate")
ISCC_DEFINES = ("SrcDir", "AppVer", "OutDir")
MIN_EXECUTED = 3845  # the executed-test floor; windows.yml's result job reads it from here
ZIP_NAME = "PokeTokenBar.zip"
WINDOWS_INSTALLER = re.compile(r"^PokeTokenBar-Setup-.+-win-x64\.exe$")

RUN_LIST_FIELDS = "databaseId,displayTitle,status,conclusion,event,createdAt,attempt,headBranch,headSha"
RUN_VIEW_FIELDS = "status,conclusion,event,workflowName,displayTitle,attempt,headBranch,headSha"
RELEASES = API + "releases?per_page=100"
LATEST = API + "releases/latest"

POLL_SECONDS = 60        # collect: one look at both runs per minute
REPORT_SECONDS = 300     # collect: one progress line per 5 minutes
APPEAR_SECONDS = 60      # start, smoke: how long a dispatched run may take to show in the run list
APPEAR_STEP = 5
VERIFY_TRIES = 3         # publish: reads of releases/latest and the tag after publishing
VERIFY_WAIT = 10

EXIT_ERROR, EXIT_RUN_FAILED, EXIT_COLLECT = 1, 3, 4
EXIT_NOT_PUBLISHED, EXIT_PUBLIC_CHECK, EXIT_ALREADY_PUBLIC = 5, 6, 7
CALL_FAILURE_EXIT = {"start": EXIT_ERROR, "collect": EXIT_COLLECT, "publish": EXIT_NOT_PUBLISHED, "smoke": EXIT_ERROR}


def installer_name(version):
    return "PokeTokenBar-Setup-%s-win-x64.exe" % version


def release_title(version, sha):
    return "release %s %s" % (version, sha)


def run_url(run_id):
    return "%s/actions/runs/%s" % (WEB, run_id)


def version_key(text):
    match = re.fullmatch(r"v?([0-9]+)\.([0-9]+)\.([0-9]+)", text or "")
    return tuple(int(part) for part in match.groups()) if match else None


Result = collections.namedtuple("Result", "code out err")


def run_process(argv):
    """The one place a process starts."""
    try:
        done = subprocess.run(argv, capture_output=True, text=True)
    except OSError as error:
        return Result(127, "", str(error))
    return Result(done.returncode, done.stdout, done.stderr)


class Stop(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


class CallFailed(Exception):
    def __init__(self, argv, result):
        detail = (result.err or result.out).strip()
        super().__init__("%s failed (exit %d)%s" % (shlex.join(argv), result.code, ": " + detail if detail else ""))


class _Calls:
    def __init__(self, runner, dry_run, say):
        self.runner, self.dry_run, self.say = runner, dry_run, say

    def _call(self, argv, write):
        if write and self.dry_run:
            raise RuntimeError("a dry run reached a write: " + shlex.join(argv))
        if write or self.dry_run:
            self.say("+ " + shlex.join(argv))
        return self.runner(argv)

    def parse(self, argv, result):
        if result.code != 0:
            raise CallFailed(argv, result)
        try:
            return json.loads(result.out)
        except ValueError:
            raise CallFailed(argv, Result(result.code, "", "not JSON: " + result.out[:200]))


GH_READS = {("run", "list"), ("run", "view"), ("run", "download")}


class Gh(_Calls):
    """`gh <args> --repo likelion-campus/PokeTokenBar`, and GET-only `gh api` under that repository."""

    def argv(self, *args):
        return ["gh"] + list(args) + ["--repo", REPO]

    def run(self, *args):
        return self._call(self.argv(*args), write=tuple(args[:2]) not in GH_READS)

    def json(self, *args):
        return self.parse(self.argv(*args), self.run(*args))

    def api_argv(self, path):
        if not path.startswith(API):
            raise ValueError("gh api path outside %s: %s" % (REPO, path))
        return ["gh", "api", path]

    def api(self, path):
        return self._call(self.api_argv(path), write=False)

    def api_json(self, path):
        return self.parse(self.api_argv(path), self.api(path))


class Git(_Calls):
    """Only `git ls-remote` against the fork's URL."""

    def ls_remote_argv(self, ref):
        return ["git", "ls-remote", GIT_URL, ref]

    def tag_commit(self, tag):
        """The commit refs/tags/<tag> points at on GitHub, or None."""
        argv = self.ls_remote_argv("refs/tags/" + tag)
        result = self._call(argv, write=False)
        if result.code != 0:
            raise CallFailed(argv, result)
        refs = {}
        for line in result.out.splitlines():
            parts = line.split()
            if len(parts) == 2:
                refs[parts[1]] = parts[0]
        return refs.get("refs/tags/%s^{}" % tag) or refs.get("refs/tags/" + tag)


class Clock:
    def now(self):
        return time.monotonic()

    def sleep(self, seconds):
        time.sleep(seconds)


class Context:
    def __init__(self, runner, dry_run, clock, root, out, err):
        self.dry_run, self.clock, self.root, self.out, self.err = dry_run, clock, root, out, err
        self.publish_stage = None  # publish: "create sent", then "edit sent"
        self.gh = Gh(runner, dry_run, self.say)
        self.git = Git(runner, dry_run, self.say)

    def say(self, message):
        print(message, file=self.err, flush=True)

    def emit(self, line):
        print(line, file=self.out, flush=True)

    def plan(self, argv, note=""):
        self.say("DRY-RUN (not run): " + shlex.join(argv) + ("    # " + note if note else ""))


# ── start ──────────────────────────────────────────────────────────────────────────────────────────────────────


def dispatch_runs(ctx, workflow_file):
    runs = ctx.gh.json("run", "list", "--workflow", workflow_file, "--event", "workflow_dispatch",
                       "--json", RUN_LIST_FIELDS, "--limit", "50")
    runs = [run for run in runs if run.get("event") == "workflow_dispatch"]
    return sorted(runs, key=lambda run: (run.get("createdAt") or "", run.get("databaseId") or 0), reverse=True)


def origin_problem(run, ref, sha):
    """Why `run` did not come from commit `sha` on branch `ref` (the release commit), or None. The title and inputs of a
    dispatched run are only what its dispatcher typed: a branch can carry its own copy of the workflow (without the release
    pin) that writes any manifest. Only the run's own head branch and commit say which workflow file ran."""
    wrong = []
    if run.get("headBranch") != ref:
        wrong.append("branch %s, expected %s" % (json.dumps(run.get("headBranch")), ref))
    if run.get("headSha") != sha:
        wrong.append("commit %s, expected %s" % (json.dumps(run.get("headSha")), sha))
    return ", ".join(wrong) or None


def release_runs(ctx, workflow_file, title, ref, sha):
    """This release's runs of one workflow that ran the release commit on `ref`, newest first. A run with this title from
    another branch or commit is never used: it is named on stderr and left out."""
    runs = []
    for run in dispatch_runs(ctx, workflow_file):
        if run.get("displayTitle") != title:
            continue
        wrong = origin_problem(run, ref, sha)
        if wrong:
            ctx.say("%s: ignoring run %s, it ran %s (%s)" % (workflow_file, run.get("databaseId"), wrong,
                                                              run_url(run.get("databaseId"))))
        else:
            runs.append(run)
    return runs


def wait_for_new_run(ctx, workflow_file, known_ids, title, origin=None):
    """The id of a run that was not in `known_ids` (and carries `title`, unless None; and, with `origin` = (ref, sha), ran
    that commit on that branch), or None after 60 s."""
    waited = 0
    while waited < APPEAR_SECONDS:
        ctx.clock.sleep(APPEAR_STEP)
        waited += APPEAR_STEP
        for run in dispatch_runs(ctx, workflow_file):
            if run.get("databaseId") not in known_ids and (title is None or run.get("displayTitle") == title):
                if origin and run.get("headBranch") == origin[0] and run.get("headSha") != origin[1]:
                    # Our own dispatch: a dispatch builds the branch's tip, and the tip is no longer the release commit.
                    raise Stop(EXIT_ERROR, "%s: %s moved to %s after the release commit %s, so the run just dispatched "
                               "(%s) builds %s's tip, not the release commit. Do not start again: pull, and release the new "
                               "tip. %s" % (workflow_file, origin[0], run.get("headSha"), origin[1], run.get("databaseId"),
                                            origin[0], run_url(run.get("databaseId"))))
                if origin and origin_problem(run, *origin):
                    ctx.say("%s: ignoring run %s, it ran %s" % (workflow_file, run.get("databaseId"),
                                                                origin_problem(run, *origin)))
                    known_ids.add(run["databaseId"])
                    continue
                return run["databaseId"]
    return None


def runs_path(root):
    return root / "build" / "windows-release" / "runs.json"


def cmd_start(args, ctx):
    title = release_title(args.version, args.sha)
    replace = set(args.new or [])
    chosen, known, to_dispatch, failed = {}, {}, [], []
    for wf in WORKFLOWS:
        runs = release_runs(ctx, wf.file, title, args.ref, args.sha)
        known[wf.file] = {run.get("databaseId") for run in runs}
        newest = runs[0] if runs else None
        if newest is None:
            to_dispatch.append(wf)
            continue
        state = "run %s (%s %s, attempt %s)" % (newest["databaseId"], newest.get("status"),
                                                newest.get("conclusion") or "-", newest.get("attempt"))
        good = newest.get("status") != "completed" or newest.get("conclusion") == "success"
        if wf.file in replace or ("failed" in replace and not good):
            ctx.say("%s: --new replaces the newest %s" % (wf.file, state))
            to_dispatch.append(wf)
        elif good:
            chosen[wf.file] = newest["databaseId"]
            ctx.say("%s: reusing %s %s" % (wf.file, state, run_url(newest["databaseId"])))
        else:
            failed.append("%s %s: %s" % (wf.file, state, run_url(newest["databaseId"])))
    if failed:
        raise Stop(EXIT_RUN_FAILED, "the newest release run for %s did not succeed; nothing was started.\n  %s\n"
                   "Read the failure first. Start a new run only for a known flake: --new failed, or --new <workflow>."
                   % (args.sha, "\n  ".join(failed)))
    for wf in to_dispatch:
        dispatch = ("workflow", "run", wf.file, "--ref", args.ref,
                    "-f", "release_sha=" + args.sha, "-f", "release_version=" + args.version)
        if ctx.dry_run:
            ctx.plan(ctx.gh.argv(*dispatch))
            continue
        result = ctx.gh.run(*dispatch)
        if result.code != 0:
            raise CallFailed(ctx.gh.argv(*dispatch), result)
        run_id = wait_for_new_run(ctx, wf.file, known[wf.file], title, (args.ref, args.sha))
        if run_id is None:
            raise Stop(EXIT_ERROR, "dispatched %s on %s, but no run titled '%s' appeared within %d s. Run start "
                       "again: it reuses the run once it shows. %s/actions/workflows/%s" % (
                           wf.file, args.ref, title, APPEAR_SECONDS, WEB, wf.file))
        chosen[wf.file] = run_id
        ctx.say("%s: started run %s %s" % (wf.file, run_id, run_url(run_id)))
    for wf in WORKFLOWS:
        if wf.file in chosen:
            ctx.emit("%s=%s" % (wf.key, chosen[wf.file]))
    if ctx.dry_run:
        ctx.say("dry run: %s not written" % runs_path(ctx.root))
        return 0
    path = runs_path(ctx.root)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"schema": 1, "sha": args.sha, "version": args.version, "ref": args.ref,
                                "runs": {wf.file: chosen[wf.file] for wf in WORKFLOWS}}, indent=2) + "\n")
    return 0


# ── collect ────────────────────────────────────────────────────────────────────────────────────────────────────


def read_runs_file(ctx, args):
    path = runs_path(ctx.root)
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise Stop(EXIT_COLLECT, "cannot read %s (%s). Run start first." % (path, error))
    data = data if isinstance(data, dict) else {}
    runs = data.get("runs")
    if data.get("sha") != args.sha or data.get("version") != args.version or not isinstance(runs, dict):
        raise Stop(EXIT_COLLECT, "%s is for release %s %s, not %s %s. Run start first." % (
            path, data.get("version"), data.get("sha"), args.version, args.sha))
    ids = {}
    for wf in WORKFLOWS:
        if not _is_int(runs.get(wf.file)):
            raise Stop(EXIT_COLLECT, "%s has no run id for %s. Run start first." % (path, wf.file))
        ids[wf.file] = runs[wf.file]
    ref = data.get("ref")
    if not isinstance(ref, str) or not ref:
        raise Stop(EXIT_COLLECT, "%s has no ref (the branch the runs were dispatched on). Run start first." % path)
    return ids, ref


def wait_for_success(ctx, ids, title, timeout_min, allow_rerun, ref, sha):
    """Both runs' attempts once both concluded success."""
    start = ctx.clock.now()
    deadline = start + timeout_min * 60
    next_report = start
    done, attempts, misses = set(), {}, 0
    while True:
        states = []
        for wf in WORKFLOWS:
            if wf.file in done:
                states.append(wf.name + " success")
                continue
            run_id = ids[wf.file]
            try:
                run = ctx.gh.json("run", "view", str(run_id), "--json", RUN_VIEW_FIELDS)
            except CallFailed as error:
                misses += 1
                if misses >= 3:
                    raise Stop(EXIT_COLLECT, "could not read the runs three times in a row: %s" % error)
                ctx.say("could not read run %s, trying again: %s" % (run_id, error))
                states.append(wf.name + " unknown")
                continue
            misses = 0
            wrong = []
            if run.get("event") != "workflow_dispatch":
                wrong.append("event %s" % run.get("event"))
            if run.get("workflowName") != wf.name:
                wrong.append("workflow %s" % run.get("workflowName"))
            if run.get("displayTitle") != title:
                wrong.append("title '%s'" % run.get("displayTitle"))
            if wrong:
                raise Stop(EXIT_COLLECT, "run %s is not a %s release run for '%s' (%s)" % (
                    run_id, wf.name, title, ", ".join(wrong)))
            foreign = origin_problem(run, ref, sha)
            if foreign:
                raise Stop(EXIT_COLLECT, "%s run %s did not run the release commit on %s: it ran %s. Its manifest and "
                           "installer cannot be trusted, because that workflow file is not the one on the release "
                           "commit. Run start again with --new %s. %s" % (
                               wf.file, run_id, ref, foreign, wf.file, run_url(run_id)))
            attempt = run.get("attempt")
            if attempts.get(wf.file) != attempt:
                ctx.say("collect: %s run %s attempt %s" % (wf.file, run_id, attempt))
                attempts[wf.file] = attempt
            if not _is_int(attempt) or attempt < 1:
                raise Stop(EXIT_COLLECT, "run %s reports attempt %s" % (run_id, json.dumps(attempt)))
            if attempt > 1 and not allow_rerun:
                raise Stop(EXIT_COLLECT, "%s run %s is attempt %d, a re-run. A re-run until green hides a flake: read "
                           "the failed attempt first; accept the re-run only on purpose, with --allow-rerun. %s" % (
                               wf.file, run_id, attempt, run_url(run_id)))
            if run.get("status") == "completed":
                if run.get("conclusion") != "success":
                    raise Stop(EXIT_COLLECT, "%s run %s concluded %s: %s" % (
                        wf.file, run_id, run.get("conclusion"), run_url(run_id)))
                done.add(wf.file)
                states.append(wf.name + " success")
            else:
                states.append("%s %s" % (wf.name, run.get("status")))
        if len(done) == len(WORKFLOWS):
            ctx.say("collect: both Windows runs succeeded")
            return attempts
        now = ctx.clock.now()
        if now >= deadline:
            raise Stop(EXIT_COLLECT, "timed out after %d min: %s. %s" % (
                timeout_min, ", ".join(states), " ".join(run_url(ids[wf.file]) for wf in WORKFLOWS)))
        if now >= next_report:
            ctx.say("collect: %d min: %s" % (int(now - start) // 60, ", ".join(states)))
            next_report += REPORT_SECONDS
        ctx.clock.sleep(POLL_SECONDS)


def file_digest(path):
    digest, size = hashlib.sha256(), 0
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
            size += len(chunk)
    return size, digest.hexdigest()


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _expect(problems, where, actual, expected):
    if type(actual) is not type(expected) or actual != expected:
        problems.append("%s is %s, expected %s" % (where, json.dumps(actual), json.dumps(expected)))


def _load(path, problems):
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        problems.append("cannot read %s: %s" % (path.name, error))
        return None
    if not isinstance(data, dict):
        problems.append("%s is not a JSON object" % path.name)
        return None
    return data


def earlier_windows_release(ctx):
    """The tag of a published release that has a Windows installer, or None."""
    for release in ctx.gh.api_json(RELEASES):
        if not release.get("draft") and any(WINDOWS_INSTALLER.match(asset.get("name") or "")
                                            for asset in release.get("assets") or []):
            return release.get("tag_name")
    return None


def check_tests_manifest(manifest, args, problems):
    _expect(problems, "windows-tests.json schema", manifest.get("schema"), 1)
    _expect(problems, "windows-tests.json sha", manifest.get("sha"), args.sha)
    _expect(problems, "windows-tests.json version", manifest.get("version"), args.version)
    executed, skipped, failures = manifest.get("executed"), manifest.get("skipped"), manifest.get("failures")
    if not _is_int(executed) or executed < MIN_EXECUTED:
        problems.append("windows-tests.json executed is %s, expected at least %d" % (json.dumps(executed), MIN_EXECUTED))
    if not _is_int(skipped) or skipped < 0:
        problems.append("windows-tests.json skipped is %s, expected a count" % json.dumps(skipped))
    _expect(problems, "windows-tests.json failures", failures, 0)
    # A release is tested on a build from scratch: release mode never restores a seed (the workflow's Seed step has `if: inputs.release_sha == ''`), and the manifest says so.
    _expect(problems, "windows-tests.json cleanBuild", manifest.get("cleanBuild"), True)


def check_release_manifest(ctx, manifest, args, app_run_id, app_attempt, local, problems):
    version, where = args.version, "windows-release.json"
    _expect(problems, where + " schema", manifest.get("schema"), 1)
    _expect(problems, where + " sha", manifest.get("sha"), args.sha)
    _expect(problems, where + " version", manifest.get("version"), version)
    _expect(problems, where + " level", manifest.get("level"), "full")
    _expect(problems, where + " cleanBuild (the shipped installer is built from scratch, never from a seed)", manifest.get("cleanBuild"), True)
    _expect(problems, where + " runId", manifest.get("runId"), app_run_id)
    _expect(problems, where + " runAttempt (the run's attempt)", manifest.get("runAttempt"), app_attempt)
    # The run's head commit is the release commit (checked in wait_for_success), and GITHUB_SHA of a dispatched run is its head commit.
    _expect(problems, where + " workflowSha (the commit the run's workflow file came from)", manifest.get("workflowSha"), args.sha)
    pins_path = Path(__file__).resolve().parent / "windows" / "build-pins.json"
    try:
        crypto_pin = json.loads(pins_path.read_text()).get("swiftCrypto")
    except (OSError, ValueError):
        crypto_pin = None
    if crypto_pin is not None:  # the release links the swift-crypto that scripts/windows/build-pins.json names
        _expect(problems, where + " swiftCrypto (the pin in scripts/windows/build-pins.json)", manifest.get("swiftCrypto"), crypto_pin)
    for key in ("runnerImage", "swift", "msvcToolset", "windowsSdk", "innoSetup", "openssl", "swiftCrypto"):
        if not isinstance(manifest.get(key), str) or not manifest[key]:
            problems.append(where + " %s is %s, expected text" % (key, json.dumps(manifest.get(key))))
    installer = manifest.get("installer") if isinstance(manifest.get("installer"), dict) else {}
    _expect(problems, where + " installer.name", installer.get("name"), installer_name(version))
    if local is not None:
        _expect(problems, where + " installer.size (the downloaded file's)", installer.get("size"), local[0])
        _expect(problems, where + " installer.sha256 (the downloaded file's)", installer.get("sha256"), local[1])
    _expect(problems, where + " installer.fileVersion", installer.get("fileVersion"), version + ".0")
    _expect(problems, where + " installer.productVersion", installer.get("productVersion"), version)
    defines = installer.get("isccDefines")
    if not isinstance(defines, list) or sorted(map(str, defines)) != sorted(ISCC_DEFINES):
        problems.append(where + " installer.isccDefines is %s, expected exactly %s" % (
            json.dumps(defines), json.dumps(list(ISCC_DEFINES))))
    app = manifest.get("app") if isinstance(manifest.get("app"), dict) else {}
    _expect(problems, where + " app.fileVersion", app.get("fileVersion"), version + ".0")
    _expect(problems, where + " app.versionFile", app.get("versionFile"), version)
    _expect(problems, where + " app.uninstallDisplayVersion", app.get("uninstallDisplayVersion"), version)
    gates = manifest.get("gates") if isinstance(manifest.get("gates"), dict) else {}
    for gate in REQUIRED_GATES:
        if gate not in gates:
            problems.append(where + " has no gate %s" % gate)
    for gate, outcome in sorted(gates.items()):
        allowed = ("success", "first") if gate == "upgradeFromRelease" else ("success",)
        if outcome not in allowed:
            problems.append(where + " gate %s is %s, expected %s" % (gate, json.dumps(outcome), " or ".join(allowed)))
    if gates.get("upgradeFromRelease") == "first":
        # "first" means the upgrade test found no earlier Windows release; once one exists, it skipped a gate.
        try:
            earlier = earlier_windows_release(ctx)
        except CallFailed as error:
            problems.append("cannot check that no earlier Windows release exists (upgradeFromRelease is first): %s" % error)
        else:
            if earlier:
                problems.append(where + " gate upgradeFromRelease is first, but %s has a Windows installer" % earlier)


def check_artifacts(ctx, args, ids, attempts, out):
    problems = []
    app_wf, tests_wf = WORKFLOWS
    name = installer_name(args.version)
    for wf, expected in ((app_wf, {app_wf.manifest, name}), (tests_wf, {tests_wf.manifest})):
        found = {path.name for path in (out / wf.artifact).iterdir()}
        if found != expected:
            problems.append("the artifact %s holds %s, expected exactly %s" % (wf.artifact, sorted(found), sorted(expected)))
    installer = out / app_wf.artifact / name
    local = file_digest(installer) if installer.is_file() else None
    tests = _load(out / tests_wf.artifact / tests_wf.manifest, problems)
    if tests is not None:
        check_tests_manifest(tests, args, problems)
    release = _load(out / app_wf.artifact / app_wf.manifest, problems)
    if release is not None:
        check_release_manifest(ctx, release, args, ids[app_wf.file], attempts.get(app_wf.file), local, problems)
    if problems:
        raise Stop(EXIT_COLLECT, "the Windows results do not match release %s %s:\n  - %s" % (
            args.version, args.sha, "\n  - ".join(problems)))
    return installer.resolve(), local


def cmd_collect(args, ctx):
    ids, ref = read_runs_file(ctx, args)
    title = release_title(args.version, args.sha)
    out = Path(args.out)
    if ctx.dry_run:
        for wf in WORKFLOWS:
            run = ctx.gh.json("run", "view", str(ids[wf.file]), "--json", RUN_VIEW_FIELDS)
            ctx.say("%s run %s: %s %s, attempt %s" % (wf.file, ids[wf.file], run.get("status"),
                                                      run.get("conclusion") or "-", run.get("attempt")))
        ctx.say("dry run: collect would poll both runs every %d s for up to %d min, then:" % (POLL_SECONDS, args.timeout_min))
        for wf in WORKFLOWS:
            ctx.plan(ctx.gh.argv("run", "download", str(ids[wf.file]), "--name", wf.artifact,
                                 "--dir", str(out / wf.artifact)), "a read; not run in a dry run")
        return 0
    attempts = wait_for_success(ctx, ids, title, args.timeout_min, args.allow_rerun, ref, args.sha)
    for wf in WORKFLOWS:
        dest = out / wf.artifact
        if dest.exists():
            shutil.rmtree(dest)
        dest.mkdir(parents=True)
        # By name is the current attempt's artifact: both workflows upload windows-release / windows-tests with overwrite: true, so a
        # re-run replaces the earlier attempt's artifact instead of leaving two (gh would take the older one). The manifest's runAttempt,
        # runId and installer hash are checked against this run below.
        download = ("run", "download", str(ids[wf.file]), "--name", wf.artifact, "--dir", str(dest))
        result = ctx.gh.run(*download)
        if result.code != 0:
            raise Stop(EXIT_COLLECT, "could not download %s: %s" % (wf.artifact, CallFailed(ctx.gh.argv(*download), result)))
    installer, (size, sha256) = check_artifacts(ctx, args, ids, attempts, out)
    ctx.say("collect: %s, %d bytes, every manifest field checked" % (installer.name, size))
    ctx.emit("INSTALLER=%s" % installer)
    ctx.emit("SHA256=%s" % sha256)
    return 0


# ── publish ────────────────────────────────────────────────────────────────────────────────────────────────────


def tagged_releases(ctx, tag):
    """Every release whose tag is `tag`, drafts included, as the REST list has them (A6)."""
    return [release for release in ctx.gh.api_json(RELEASES) if release.get("tag_name") == tag]


def listing(releases):
    return ", ".join("id %s %s" % (release.get("id"), "draft" if release.get("draft") is True else "public")
                     for release in releases) or "none"


def not_alone(tag, tagged, our_id, when):
    """The stop when the tag is not this run's alone: nothing is edited or deleted."""
    public = any(release.get("draft") is not True for release in tagged)
    return Stop(EXIT_PUBLIC_CHECK if public else EXIT_NOT_PUBLISHED,
                "%s: %d releases carry the tag %s (%s), and this run's draft is %s. Another session may be releasing "
                "%s. Nothing was edited or deleted: check %s/releases by hand%s." % (
                    when, len(tagged), tag, listing(tagged), "id %s" % our_id if our_id else "not known", tag, WEB,
                    "; a public release carries the tag" if public else "; none of them is public"))


def newer_latest(ctx, version):
    """The tag of releases/latest when it is newer than `version` or cannot be compared, else None."""
    result = ctx.gh.api(LATEST)
    if result.code != 0 and "HTTP 404" in result.err:
        return None
    latest = ctx.gh.parse(ctx.gh.api_argv(LATEST), result).get("tag_name")
    key = version_key(latest)
    return latest if key is None or key > version_key(version) else None


def asset_problems(assets, local):
    problems = []
    assets = assets if isinstance(assets, list) else []
    names = [asset.get("name") for asset in assets]
    if sorted(map(str, names)) != sorted(local):
        problems.append("the assets are %s, expected exactly %s" % (names, sorted(local)))
    for asset in assets:
        if asset.get("name") not in local:
            continue
        size, sha256 = local[asset["name"]]
        if asset.get("state") != "uploaded":
            problems.append("%s is %s, not uploaded" % (asset["name"], asset.get("state")))
        if asset.get("size") != size:
            problems.append("%s is %s bytes on GitHub, %d here" % (asset["name"], asset.get("size"), size))
        if asset.get("digest") != "sha256:" + sha256:
            problems.append("%s has digest %s on GitHub, sha256:%s here" % (asset["name"], asset.get("digest"), sha256))
    return problems


def draft_problems(release, tag, sha, local):
    problems = []
    if release.get("draft") is not True:
        problems.append("%s (id %s) is not a draft" % (tag, release.get("id")))
    if release.get("target_commitish") != sha:
        problems.append("the draft targets %s, not %s" % (release.get("target_commitish"), sha))
    return problems + asset_problems(release.get("assets"), local)


def published_problems(ctx, tag, sha, our_id, local):
    problems = []
    try:
        latest = ctx.gh.api_json(LATEST)
        if latest.get("id") != our_id:
            problems.append("releases/latest is %s (id %s), not this run's %s (id %s)" % (
                latest.get("tag_name"), latest.get("id"), tag, our_id))
        else:
            if latest.get("target_commitish") != sha:
                problems.append("releases/latest targets %s, not %s" % (latest.get("target_commitish"), sha))
            problems += asset_problems(latest.get("assets"), local)
        at = ctx.git.tag_commit(tag)
        if at != sha:
            problems.append("tag %s points at %s, not %s" % (tag, at, sha))
    except CallFailed as error:
        problems.append(str(error))
    return problems


def check_still_ours(ctx, tag, our_id):
    """Right before the edit: exactly one release carries the tag, it is this run's, and it is a draft."""
    tagged = tagged_releases(ctx, tag)
    if len(tagged) != 1 or tagged[0].get("id") != our_id:
        raise not_alone(tag, tagged, our_id, "Before publishing")
    if tagged[0].get("draft") is not True:
        raise Stop(EXIT_PUBLIC_CHECK, "before this run sent its publish request, its draft %s (id %s) reads as public: "
                   "someone else published it. Nothing was edited or deleted; check %s/releases/tag/%s, its assets "
                   "and digests, and the tag." % (tag, our_id, WEB, tag))


def remove_own_draft(ctx, tag, our_id, edit_sent, reason):
    """Stop before publishing: delete this run's draft, only right after a fresh read shows it is a draft, it is this
    run's (by id), and no other release carries the tag."""
    ctx.say("publish: stopping before publishing: %s" % reason)
    try:
        tagged = tagged_releases(ctx, tag)
    except CallFailed as error:
        raise Stop(EXIT_PUBLIC_CHECK, "%s. Then the releases could not be read again (%s), so nothing was deleted. "
                   "Check %s/releases by hand: %s may be a draft or public." % (reason, error, WEB, tag))
    if not tagged:
        raise Stop(EXIT_NOT_PUBLISHED, "%s. No release %s exists; nothing was published." % (reason, tag))
    if our_id is None and len(tagged) == 1:
        our_id = tagged[0].get("id")  # create failed or was not read: the one release with the tag is this run's
    if len(tagged) != 1 or tagged[0].get("id") != our_id:
        raise not_alone(tag, tagged, our_id, reason + ". At cleanup")
    if tagged[0].get("draft") is not True:
        if edit_sent:
            how = ("this run sent its publish request (gh release edit), which failed or was interrupted, and the "
                   "release reads public, so that request most likely went through")
        else:
            how = "this run never sent its publish request, so someone else published this run's draft"
        raise Stop(EXIT_PUBLIC_CHECK, "%s. Release %s (id %s) reads as public: %s. Nothing was deleted. Check "
                   "%s/releases/tag/%s, its assets and digests, and the tag." % (reason, tag, our_id, how, WEB, tag))
    result = ctx.gh.run("release", "delete", tag, "--yes")
    if result.code != 0:
        raise Stop(EXIT_NOT_PUBLISHED, "%s. Deleting this run's draft (id %s) failed (%s): delete the draft %s on "
                   "%s/releases before running again. Nothing was published." % (
                       reason, our_id, (result.err or result.out).strip(), tag, WEB))
    raise Stop(EXIT_NOT_PUBLISHED, "%s. The draft this run created (id %s) was deleted; nothing was published." % (
        reason, our_id))


def local_assets(args):
    """{asset name: (size, sha256)} for the two files, once the files, the manifest `collect` left beside the
    installer, and the notes all match this release."""
    zip_path, installer, notes = Path(args.zip), Path(args.installer), Path(args.notes)
    problems = []
    if zip_path.name != ZIP_NAME:
        problems.append("the zip is named %s, expected %s" % (zip_path.name, ZIP_NAME))
    if installer.name != installer_name(args.version):
        problems.append("the installer is named %s, expected %s" % (installer.name, installer_name(args.version)))
    for path in (zip_path, installer):
        if not path.is_file() or path.stat().st_size == 0:
            problems.append("%s is missing or empty" % path)
    if problems:
        raise Stop(EXIT_NOT_PUBLISHED, "nothing was created: " + "; ".join(problems))
    local = {ZIP_NAME: file_digest(zip_path), installer.name: file_digest(installer)}
    size, sha256 = local[installer.name]
    manifest = _load(installer.parent / WORKFLOWS[0].manifest, problems)
    if manifest is not None:
        where = "the installer's %s" % WORKFLOWS[0].manifest
        _expect(problems, where + " sha", manifest.get("sha"), args.sha)
        _expect(problems, where + " version", manifest.get("version"), args.version)
        entry = manifest.get("installer") if isinstance(manifest.get("installer"), dict) else {}
        _expect(problems, where + " installer.name", entry.get("name"), installer.name)
        _expect(problems, where + " installer.size (the file's)", entry.get("size"), size)
        _expect(problems, where + " installer.sha256 (the file's)", entry.get("sha256"), sha256)
    text = notes.read_text() if notes.is_file() else ""
    if not text.strip():
        problems.append("the notes %s are missing or empty" % notes)
    elif "{{" in text:
        problems.append("the notes still hold a {{…}} token")
    elif sha256 not in text:
        problems.append("the notes do not carry the installer's SHA-256 %s" % sha256)
    if problems:
        raise Stop(EXIT_NOT_PUBLISHED, "nothing was created: " + "; ".join(problems))
    return local


def cmd_publish(args, ctx):
    tag, sha = "v" + args.version, args.sha
    local = local_assets(args)
    existing = tagged_releases(ctx, tag)
    if any(release.get("draft") is not True for release in existing):
        raise Stop(EXIT_ALREADY_PUBLIC, "release %s is already public (%s). This run created nothing. Do not update "
                   "the tap with this run's zip; check that release by hand." % (tag, listing(existing)))
    if existing:
        raise Stop(EXIT_NOT_PUBLISHED, "draft %s exists already (%s; left by an earlier run, or another session is "
                   "releasing %s) and is not reused. Check it on %s/releases, delete it there if it is stale, then run "
                   "again. Nothing was created." % (tag, listing(existing), tag, WEB))
    tagged = ctx.git.tag_commit(tag)
    if tagged is not None:
        raise Stop(EXIT_NOT_PUBLISHED, "tag %s exists already (at %s); GitHub would ignore --target. Nothing was "
                   "created; check where the tag came from." % (tag, tagged))
    newer = newer_latest(ctx, args.version)
    if newer:
        raise Stop(EXIT_NOT_PUBLISHED, "releases/latest is %s, which is newer than %s (or not comparable): publishing "
                   "with --latest would make an older version latest. Nothing was created." % (newer, tag))
    create = ("release", "create", tag, args.zip, args.installer, "--draft", "--target", sha,
              "--title", tag, "--notes-file", args.notes)
    publish = ("release", "edit", tag, "--draft=false", "--latest")
    if ctx.dry_run:
        ctx.say("dry run: the checks before create passed; publish would run:")
        ctx.plan(ctx.gh.argv(*create))
        ctx.plan(ctx.gh.api_argv(RELEASES), "exactly one release tagged %s: this run's id; a draft at the target, "
                 "both assets uploaded with these digests" % tag)
        ctx.plan(ctx.git.ls_remote_argv("refs/tags/" + tag), "no tag while it is a draft")
        ctx.plan(ctx.gh.api_argv(LATEST), "not newer than " + tag)
        ctx.plan(ctx.gh.api_argv(RELEASES), "still exactly one release tagged %s, this run's draft" % tag)
        ctx.plan(ctx.gh.argv(*publish))
        ctx.plan(ctx.gh.api_argv(LATEST), "this run's release, with the same assets and digests")
        ctx.plan(ctx.git.ls_remote_argv("refs/tags/" + tag), "points at " + sha)
        ctx.say("on a failure before the publish request is answered:")
        ctx.plan(ctx.gh.api_argv(RELEASES), "re-read: exactly one release tagged %s, this run's id, still a draft" % tag)
        ctx.plan(ctx.gh.argv("release", "delete", tag, "--yes"), "only if that read says so")
        for name, (size, sha256) in sorted(local.items()):
            ctx.say("  %s %d bytes sha256:%s" % (name, size, sha256))
        return 0
    our_id, edit_sent = None, False
    ctx.publish_stage = "create sent"
    try:
        result = ctx.gh.run(*create)
        if result.code != 0:
            remove_own_draft(ctx, tag, our_id, edit_sent, "gh release create failed (exit %d): %s" % (
                result.code, (result.err or result.out).strip()))
        mine = tagged_releases(ctx, tag)
        if len(mine) != 1:
            raise not_alone(tag, mine, None, "Right after create")
        our_id = mine[0].get("id")
        problems = draft_problems(mine[0], tag, sha, local)
        tagged = ctx.git.tag_commit(tag)
        if tagged is not None:
            problems.append("tag %s exists (at %s) while the release is a draft; it stays, check it by hand" % (tag, tagged))
        if problems:
            remove_own_draft(ctx, tag, our_id, edit_sent, "the draft (id %s) does not match: %s" % (
                our_id, "; ".join(problems)))
        ctx.say("publish: the draft (id %s) has both assets with the local SHA-256" % our_id)
        newer = newer_latest(ctx, args.version)
        if newer:
            remove_own_draft(ctx, tag, our_id, edit_sent, "releases/latest became %s, newer than %s (or not "
                             "comparable): publishing with --latest would make an older version latest" % (newer, tag))
        check_still_ours(ctx, tag, our_id)
        edit_sent, ctx.publish_stage = True, "edit sent"
        result = ctx.gh.run(*publish)
        if result.code != 0:
            remove_own_draft(ctx, tag, our_id, edit_sent, "gh release edit failed (exit %d): %s" % (
                result.code, (result.err or result.out).strip()))
    except CallFailed as error:
        remove_own_draft(ctx, tag, our_id, edit_sent, str(error))
    except KeyboardInterrupt:
        remove_own_draft(ctx, tag, our_id, edit_sent, "interrupted")
    try:
        for attempt in range(VERIFY_TRIES):
            if attempt:
                ctx.clock.sleep(VERIFY_WAIT)
            problems = published_problems(ctx, tag, sha, our_id, local)
            if not problems:
                break
    except KeyboardInterrupt:
        problems = ["interrupted while checking"]
    if problems:
        raise Stop(EXIT_PUBLIC_CHECK, "%s (id %s) is published, but a check failed:\n  - %s\nNothing was deleted. Check "
                   "%s/releases/tag/%s, `gh api %s` and `git ls-remote %s refs/tags/%s` (expected %s)." % (
                       tag, our_id, "\n  - ".join(problems), WEB, tag, LATEST, GIT_URL, tag, sha))
    ctx.say("publish: %s (id %s) is public and latest, with both assets and their digests; the tag points at %s" % (
        tag, our_id, sha))
    return 0


# ── smoke ──────────────────────────────────────────────────────────────────────────────────────────────────────


def cmd_smoke(args, ctx):
    path = "%scontents/.github/workflows/%s?ref=%s" % (API, SMOKE_WORKFLOW, urllib.parse.quote(args.ref, safe=""))
    result = ctx.gh.api(path)
    if result.code != 0:
        if "HTTP 404" in result.err:
            ctx.emit("no smoke workflow yet")
            return 0
        raise CallFailed(ctx.gh.api_argv(path), result)
    known = {run.get("databaseId") for run in dispatch_runs(ctx, SMOKE_WORKFLOW)}
    dispatch = ("workflow", "run", SMOKE_WORKFLOW, "--ref", args.ref, "-f", "version=" + args.version)
    if ctx.dry_run:
        ctx.plan(ctx.gh.argv(*dispatch))
        return 0
    result = ctx.gh.run(*dispatch)
    if result.code != 0:
        raise CallFailed(ctx.gh.argv(*dispatch), result)
    run_id = wait_for_new_run(ctx, SMOKE_WORKFLOW, known, None)
    if run_id is None:
        ctx.say("the smoke run did not show within %d s; its runs are listed at:" % APPEAR_SECONDS)
        ctx.emit("%s/actions/workflows/%s" % (WEB, SMOKE_WORKFLOW))
    else:
        ctx.emit(run_url(run_id))
    return 0


# ── command line ───────────────────────────────────────────────────────────────────────────────────────────────


def _sha(text):
    if not re.fullmatch(r"[0-9a-f]{40}", text):
        raise argparse.ArgumentTypeError("expected a 40-character lowercase hex commit SHA")
    return text


def _version(text):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", text):
        raise argparse.ArgumentTypeError("expected x.y.z")
    return text


def build_parser():
    parser = argparse.ArgumentParser(prog="team_release.py", description=__doc__.split("\n\n")[0])
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--dry-run", action="store_true", help="run only read-only calls; print every write")
    sub = parser.add_subparsers(dest="command", required=True)
    start = sub.add_parser("start", parents=[common], help="find or start this commit's release runs")
    collect = sub.add_parser("collect", parents=[common], help="wait for both runs, download and check their results")
    publish = sub.add_parser("publish", parents=[common], help="draft, check, publish and check the release")
    for command in (start, collect, publish):
        command.add_argument("--sha", required=True, type=_sha)
        command.add_argument("--version", required=True, type=_version)
    start.add_argument("--ref", default="main")
    start.add_argument("--new", action="append", nargs="?", const="failed",
                       choices=("failed",) + tuple(wf.file for wf in WORKFLOWS),
                       help="start a new run: alone or 'failed' in place of a failed one; a workflow file: in place "
                            "of that workflow's newest run, whatever its state (repeatable)")
    collect.add_argument("--out", required=True)
    collect.add_argument("--timeout-min", type=int, default=170)  # above the slowest path of windows-app (build 60 min, then the longest job 60 min, then result)
    collect.add_argument("--allow-rerun", action="store_true", help="accept a run whose attempt is above 1")
    publish.add_argument("--zip", required=True)
    publish.add_argument("--installer", required=True)
    publish.add_argument("--notes", required=True)
    smoke = sub.add_parser("smoke", parents=[common], help="start the post-release smoke run")
    smoke.add_argument("--version", required=True, type=_version)
    smoke.add_argument("--ref", default="main")
    return parser


COMMANDS = {"start": cmd_start, "collect": cmd_collect, "publish": cmd_publish, "smoke": cmd_smoke}


def _interrupt(signum, frame):
    raise KeyboardInterrupt


def main(argv=None, runner=run_process, clock=None, root=ROOT, out=None, err=None):
    args = build_parser().parse_args(argv)
    ctx = Context(runner, args.dry_run, clock or Clock(), Path(root), out or sys.stdout, err or sys.stderr)
    # A release run in the background is stopped with SIGTERM or SIGHUP, not Ctrl-C: all three take the same cleanup.
    previous = {sig: signal.signal(sig, _interrupt) for sig in (signal.SIGTERM, signal.SIGHUP)}
    try:
        return COMMANDS[args.command](args, ctx)
    except Stop as stop:
        ctx.say("team_release %s: %s" % (args.command, stop))
        return stop.code
    except CallFailed as error:
        ctx.say("team_release %s: %s" % (args.command, error))
        return CALL_FAILURE_EXIT[args.command]
    except KeyboardInterrupt:
        # publish reaches this only when interrupted before create, or again while cleaning up.
        stage = ctx.publish_stage
        said = {None: "", "create sent": "; nothing was published, but a draft this run created may remain: check "
                "%s/releases" % WEB, "edit sent": "; this run had sent its publish request, so the release may be "
                "public: check %s/releases by hand" % WEB}[stage]
        ctx.say("team_release %s: interrupted%s" % (args.command, said or (
            "; nothing was created" if args.command == "publish" else "")))
        return EXIT_PUBLIC_CHECK if stage == "edit sent" else CALL_FAILURE_EXIT[args.command]
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


if __name__ == "__main__":
    sys.exit(main())
