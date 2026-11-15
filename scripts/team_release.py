#!/usr/bin/env python3
"""The team fork's release writer: the Windows runs, their checks, and the one GitHub release of both systems.

Only this helper writes a release of likelion-campus/PokeTokenBar (stage 8 plan, D2). The Windows workflows keep
`contents: read`. scripts/team-release.sh calls the subcommands in the order of D3:

  start   --sha SHA --version V [--ref main] [--new]
  collect --sha SHA --version V --out DIR [--timeout-min 100]
  publish --sha SHA --version V --zip PATH --installer PATH --notes PATH
  smoke   --version V [--ref main]

Every subcommand also takes --dry-run: read-only calls run, and every write (a workflow dispatch, a release create,
edit or delete) is printed instead of run. `collect --dry-run` reads each run once and prints what it would download.

Exit codes (team-release.sh relies on them):
  0  done
  1  start or smoke: a gh or git call failed, or a dispatched run did not appear within 60 s. Nothing was published.
  2  bad arguments
  3  start: the newest release run for this SHA failed or was cancelled. A new one starts only with --new.
  4  collect: a run failed, was cancelled or timed out; a download failed; a manifest or a hash does not match.
  5  publish: stopped before publishing. A draft this run created was deleted; the message says if one remains.
  6  publish: the release is (or may be) public and a check failed. Nothing was deleted: check it by hand.

Every gh and git call goes through one runner (`run_process`; the tests inject a fake GitHub). `Gh` appends
`--repo likelion-campus/PokeTokenBar`; `Gh.api` only GETs paths under repos/likelion-campus/PokeTokenBar/; `Git` only
runs `git ls-remote` against the fork's URL. Nothing here pushes, creates or deletes a tag, or deletes a published
release. A release is deleted only right after a fresh read says it is still a draft.

What this relies on about gh 2.88 and GitHub (risk K3). Read in gh v2.88.1's source and the REST docs on 2026-11-16;
the tests' FakeGitHub encodes the same list:
  A1 `gh release create --draft` makes a draft with the pending tag name and creates no git tag. The tag is created
     at `target_commitish` when the draft is published. (REST docs: target_commitish "determines where the Git tag is
     created from" and is "unused if the Git tag already exists", so publish refuses an existing tag.) The draft
     check also reads the tag: a tag that exists while the release is a draft stops the release.
  A2 `gh release view/edit/delete <tag>` find a draft by its pending tag (gh FetchRelease: GraphQL
     `release(tagName:)`, then REST by id). The REST "get a release by tag name" returns published releases only.
  A3 An asset uploaded to a draft has `state: uploaded` and `digest: sha256:<hex>`. Seen on every published release;
     on a draft it is unverified. The REST schema says "string or null": a null digest fails the draft check, so
     the draft is deleted and nothing is published.
  A4 `gh release edit <tag> --draft=false --latest` sends one PATCH {draft: false, make_latest: "true"}, the same
     request gh's own create sends when it publishes a release it uploaded as a draft.
  A5 With an explicit --draft, gh does NOT delete the draft when an upload fails (its cleanup runs only for its own
     draft-while-uploading), and does not check for an existing release with that tag. This helper does both.
"""
import argparse
import collections
import hashlib
import json
import re
import shlex
import shutil
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
REQUIRED_GATES = ("bundleSelftest", "install", "upgrade", "installedSelftest", "idle", "uninstall", "upgradeFromRelease")
ISCC_DEFINES = ("SrcDir", "AppVer", "OutDir")
MIN_EXECUTED = 2400
ZIP_NAME = "PokeTokenBar.zip"
WINDOWS_INSTALLER = re.compile(r"^PokeTokenBar-Setup-.+-win-x64\.exe$")

RUN_LIST_FIELDS = "databaseId,displayTitle,status,conclusion,event,createdAt"
RUN_VIEW_FIELDS = "status,conclusion,event,workflowName,displayTitle"
RELEASE_FIELDS = "isDraft,tagName,targetCommitish,assets,url"

POLL_SECONDS = 60        # collect: one look at both runs per minute
REPORT_SECONDS = 300     # collect: one progress line per 5 minutes
APPEAR_SECONDS = 60      # start, smoke: how long a dispatched run may take to show in the run list
APPEAR_STEP = 5
VERIFY_TRIES = 3         # publish: reads of releases/latest and the tag after publishing
VERIFY_WAIT = 10

EXIT_ERROR, EXIT_RUN_FAILED, EXIT_COLLECT, EXIT_NOT_PUBLISHED, EXIT_PUBLISHED_CHECK = 1, 3, 4, 5, 6
CALL_FAILURE_EXIT = {"start": EXIT_ERROR, "collect": EXIT_COLLECT, "publish": EXIT_NOT_PUBLISHED, "smoke": EXIT_ERROR}


def installer_name(version):
    return "PokeTokenBar-Setup-%s-win-x64.exe" % version


def release_title(version, sha):
    return "release %s %s" % (version, sha)


def run_url(run_id):
    return "%s/actions/runs/%s" % (WEB, run_id)


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


GH_READS = {("run", "list"), ("run", "view"), ("run", "download"), ("release", "view")}


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


def release_runs(ctx, workflow_file, title):
    """This release's runs of one workflow, newest first."""
    return [run for run in dispatch_runs(ctx, workflow_file) if run.get("displayTitle") == title]


def wait_for_new_run(ctx, workflow_file, known_ids, title):
    """The id of a run that was not in `known_ids` (and carries `title`, unless None), or None after 60 s."""
    waited = 0
    while waited < APPEAR_SECONDS:
        ctx.clock.sleep(APPEAR_STEP)
        waited += APPEAR_STEP
        for run in dispatch_runs(ctx, workflow_file):
            if run.get("databaseId") not in known_ids and (title is None or run.get("displayTitle") == title):
                return run["databaseId"]
    return None


def runs_path(root):
    return root / "build" / "windows-release" / "runs.json"


def cmd_start(args, ctx):
    title = release_title(args.version, args.sha)
    chosen, known, to_dispatch, failed = {}, {}, [], []
    for wf in WORKFLOWS:
        runs = release_runs(ctx, wf.file, title)
        known[wf.file] = {run.get("databaseId") for run in runs}
        newest = runs[0] if runs else None
        if newest is None:
            to_dispatch.append(wf)
        elif newest.get("status") != "completed" or newest.get("conclusion") == "success":
            chosen[wf.file] = newest["databaseId"]
            ctx.say("%s: reusing run %s (%s %s) %s" % (wf.file, newest["databaseId"], newest.get("status"),
                                                       newest.get("conclusion") or "", run_url(newest["databaseId"])))
        elif args.new:
            ctx.say("%s: the newest run %s concluded %s; --new starts another" % (
                wf.file, newest["databaseId"], newest.get("conclusion")))
            to_dispatch.append(wf)
        else:
            failed.append("%s run %s concluded %s: %s" % (wf.file, newest["databaseId"], newest.get("conclusion"),
                                                          run_url(newest["databaseId"])))
    if failed:
        raise Stop(EXIT_RUN_FAILED, "the newest release run for %s failed; nothing was started.\n  %s\n"
                   "Read the failure first. Start a new run only for a known flake, with --new." % (
                       args.sha, "\n  ".join(failed)))
    for wf in to_dispatch:
        dispatch = ("workflow", "run", wf.file, "--ref", args.ref,
                    "-f", "release_sha=" + args.sha, "-f", "release_version=" + args.version)
        if ctx.dry_run:
            ctx.plan(ctx.gh.argv(*dispatch))
            continue
        result = ctx.gh.run(*dispatch)
        if result.code != 0:
            raise CallFailed(ctx.gh.argv(*dispatch), result)
        run_id = wait_for_new_run(ctx, wf.file, known[wf.file], title)
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
    return ids


def wait_for_success(ctx, ids, title, timeout_min):
    start = ctx.clock.now()
    deadline = start + timeout_min * 60
    next_report = start
    done, misses = set(), 0
    while True:
        states = []
        for wf in WORKFLOWS:
            if wf.file in done:
                states.append(wf.name + " success")
                continue
            run_id = ids[wf.file]
            argv = ctx.gh.argv("run", "view", str(run_id), "--json", RUN_VIEW_FIELDS)
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
                raise Stop(EXIT_COLLECT, "run %s is not a %s release run for '%s' (%s; %s)" % (
                    run_id, wf.name, title, ", ".join(wrong), shlex.join(argv)))
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
            return
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
    for release in ctx.gh.api_json(API + "releases?per_page=100"):
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


def check_release_manifest(ctx, manifest, args, app_run_id, local, problems):
    version, where = args.version, "windows-release.json"
    _expect(problems, where + " schema", manifest.get("schema"), 1)
    _expect(problems, where + " sha", manifest.get("sha"), args.sha)
    _expect(problems, where + " version", manifest.get("version"), version)
    _expect(problems, where + " level", manifest.get("level"), "full")
    _expect(problems, where + " runId", manifest.get("runId"), app_run_id)
    if not re.fullmatch(r"[0-9a-f]{40}", str(manifest.get("workflowSha"))):
        problems.append(where + " workflowSha is %s, expected a commit SHA" % json.dumps(manifest.get("workflowSha")))
    if not _is_int(manifest.get("runAttempt")) or manifest["runAttempt"] < 1:
        problems.append(where + " runAttempt is %s" % json.dumps(manifest.get("runAttempt")))
    for key in ("runnerImage", "swift"):
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


def check_artifacts(ctx, args, ids, out):
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
        check_release_manifest(ctx, release, args, ids[app_wf.file], local, problems)
    if problems:
        raise Stop(EXIT_COLLECT, "the Windows results do not match release %s %s:\n  - %s" % (
            args.version, args.sha, "\n  - ".join(problems)))
    return installer.resolve(), local


def cmd_collect(args, ctx):
    ids = read_runs_file(ctx, args)
    title = release_title(args.version, args.sha)
    out = Path(args.out)
    if ctx.dry_run:
        for wf in WORKFLOWS:
            run = ctx.gh.json("run", "view", str(ids[wf.file]), "--json", RUN_VIEW_FIELDS)
            ctx.say("%s run %s: %s %s" % (wf.file, ids[wf.file], run.get("status"), run.get("conclusion") or ""))
        ctx.say("dry run: collect would poll both runs every %d s for up to %d min, then:" % (POLL_SECONDS, args.timeout_min))
        for wf in WORKFLOWS:
            ctx.plan(ctx.gh.argv("run", "download", str(ids[wf.file]), "--name", wf.artifact,
                                 "--dir", str(out / wf.artifact)), "a read; not run in a dry run")
        return 0
    wait_for_success(ctx, ids, title, args.timeout_min)
    for wf in WORKFLOWS:
        dest = out / wf.artifact
        if dest.exists():
            shutil.rmtree(dest)
        dest.mkdir(parents=True)
        download = ("run", "download", str(ids[wf.file]), "--name", wf.artifact, "--dir", str(dest))
        result = ctx.gh.run(*download)
        if result.code != 0:
            raise Stop(EXIT_COLLECT, "could not download %s: %s" % (wf.artifact, CallFailed(ctx.gh.argv(*download), result)))
    installer, (size, sha256) = check_artifacts(ctx, args, ids, out)
    ctx.say("collect: %s, %d bytes, every manifest field checked" % (installer.name, size))
    ctx.emit("INSTALLER=%s" % installer)
    ctx.emit("SHA256=%s" % sha256)
    return 0


# ── publish ────────────────────────────────────────────────────────────────────────────────────────────────────


def read_release(ctx, tag):
    """The release (published, or a draft by its pending tag) as `gh release view` sees it, or None."""
    argv = ctx.gh.argv("release", "view", tag, "--json", RELEASE_FIELDS)
    result = ctx.gh.run("release", "view", tag, "--json", RELEASE_FIELDS)
    if result.code != 0 and "release not found" in result.err:
        return None
    return ctx.gh.parse(argv, result)


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
    if release.get("isDraft") is not True:
        problems.append("%s is not a draft" % tag)
    if release.get("tagName") != tag:
        problems.append("the draft's tag is %s" % release.get("tagName"))
    if release.get("targetCommitish") != sha:
        problems.append("the draft targets %s, not %s" % (release.get("targetCommitish"), sha))
    return problems + asset_problems(release.get("assets"), local)


def published_problems(ctx, tag, sha, local):
    problems = []
    try:
        latest = ctx.gh.api_json(API + "releases/latest")
        if latest.get("tag_name") != tag:
            problems.append("releases/latest is %s, not %s" % (latest.get("tag_name"), tag))
        else:
            if latest.get("draft") is not False:
                problems.append("releases/latest says %s is a draft" % tag)
            if latest.get("target_commitish") != sha:
                problems.append("releases/latest targets %s, not %s" % (latest.get("target_commitish"), sha))
            problems += asset_problems(latest.get("assets"), local)
        at = ctx.git.tag_commit(tag)
        if at != sha:
            problems.append("tag %s points at %s, not %s" % (tag, at, sha))
    except CallFailed as error:
        problems.append(str(error))
    return problems


def remove_own_draft(ctx, tag, reason):
    """Stop before publishing: delete this run's draft, but only right after a fresh read says it is still a draft."""
    ctx.say("publish: stopping before publishing: %s" % reason)
    try:
        current = read_release(ctx, tag)
    except CallFailed as error:
        raise Stop(EXIT_PUBLISHED_CHECK, "%s. Then the release could not be read again (%s), so nothing was deleted. "
                   "Check %s/releases by hand: %s may be a draft or public." % (reason, error, WEB, tag))
    if current is None:
        raise Stop(EXIT_NOT_PUBLISHED, "%s. No release %s exists; nothing was published." % (reason, tag))
    if current.get("isDraft") is not True:
        raise Stop(EXIT_PUBLISHED_CHECK, "%s. Release %s is public although this run did not publish it; nothing was "
                   "deleted. Check %s, its assets and digests, and the tag." % (reason, tag, current.get("url")))
    result = ctx.gh.run("release", "delete", tag, "--yes")
    if result.code != 0:
        raise Stop(EXIT_NOT_PUBLISHED, "%s. Deleting this run's draft failed (%s): delete the draft %s on %s/releases "
                   "before running again. Nothing was published." % (reason, (result.err or result.out).strip(), tag, WEB))
    raise Stop(EXIT_NOT_PUBLISHED, "%s. The draft this run created was deleted; nothing was published." % reason)


def local_assets(args):
    """{asset name: (size, sha256)} for the two files, after their names and the notes are checked."""
    zip_path, installer, notes = Path(args.zip), Path(args.installer), Path(args.notes)
    problems = []
    if zip_path.name != ZIP_NAME:
        problems.append("the zip is named %s, expected %s" % (zip_path.name, ZIP_NAME))
    if installer.name != installer_name(args.version):
        problems.append("the installer is named %s, expected %s" % (installer.name, installer_name(args.version)))
    for path in (zip_path, installer):
        if not path.is_file() or path.stat().st_size == 0:
            problems.append("%s is missing or empty" % path)
    if not notes.is_file() or not notes.read_text().strip():
        problems.append("the notes %s are missing or empty" % notes)
    if problems:
        raise Stop(EXIT_NOT_PUBLISHED, "nothing was created: " + "; ".join(problems))
    return {ZIP_NAME: file_digest(zip_path), installer.name: file_digest(installer)}


def cmd_publish(args, ctx):
    tag, sha = "v" + args.version, args.sha
    local = local_assets(args)
    existing = read_release(ctx, tag)
    if existing is not None:
        if existing.get("isDraft") is True:
            raise Stop(EXIT_NOT_PUBLISHED, "a draft %s exists already (left by an earlier run?) and is not reused. Check "
                       "it on %s/releases, delete it there, then run again. Nothing was created." % (tag, WEB))
        raise Stop(EXIT_NOT_PUBLISHED, "release %s is already published (%s). This run created nothing; check that "
                   "release by hand." % (tag, existing.get("url")))
    tagged = ctx.git.tag_commit(tag)
    if tagged is not None:
        raise Stop(EXIT_NOT_PUBLISHED, "tag %s exists already (at %s); GitHub would ignore --target. Nothing was "
                   "created; check where the tag came from." % (tag, tagged))
    create = ("release", "create", tag, args.zip, args.installer, "--draft", "--target", sha,
              "--title", tag, "--notes-file", args.notes)
    publish = ("release", "edit", tag, "--draft=false", "--latest")
    if ctx.dry_run:
        ctx.say("dry run: the checks before create passed; publish would run:")
        ctx.plan(ctx.gh.argv(*create))
        ctx.plan(ctx.gh.argv("release", "view", tag, "--json", RELEASE_FIELDS), "a draft, at the target, the two assets uploaded with these digests")
        ctx.plan(ctx.git.ls_remote_argv("refs/tags/" + tag), "no tag while it is a draft")
        ctx.plan(ctx.gh.argv(*publish))
        ctx.plan(ctx.gh.api_argv(API + "releases/latest"), "names %s with the same assets and digests" % tag)
        ctx.plan(ctx.git.ls_remote_argv("refs/tags/" + tag), "points at " + sha)
        ctx.say("on a failure before the edit:")
        ctx.plan(ctx.gh.argv("release", "view", tag, "--json", RELEASE_FIELDS), "re-read isDraft")
        ctx.plan(ctx.gh.argv("release", "delete", tag, "--yes"), "only if that read says isDraft == true")
        for name, (size, sha256) in sorted(local.items()):
            ctx.say("  %s %d bytes sha256:%s" % (name, size, sha256))
        return 0
    try:
        result = ctx.gh.run(*create)
        if result.code != 0:
            remove_own_draft(ctx, tag, "gh release create failed (exit %d): %s" % (
                result.code, (result.err or result.out).strip()))
        draft = read_release(ctx, tag)
        if draft is None:
            raise Stop(EXIT_NOT_PUBLISHED, "gh release create succeeded, but no release %s can be read. Nothing was "
                       "published; look for a leftover draft on %s/releases." % (tag, WEB))
        problems = draft_problems(draft, tag, sha, local)
        tagged = ctx.git.tag_commit(tag)
        if tagged is not None:
            problems.append("tag %s exists (at %s) while the release is a draft; it stays, check it by hand" % (tag, tagged))
        if problems:
            remove_own_draft(ctx, tag, "the draft does not match: " + "; ".join(problems))
        ctx.say("publish: the draft has both assets with the local SHA-256")
        result = ctx.gh.run(*publish)
        if result.code != 0:
            remove_own_draft(ctx, tag, "gh release edit failed (exit %d): %s" % (result.code, (result.err or result.out).strip()))
    except CallFailed as error:
        remove_own_draft(ctx, tag, str(error))
    except KeyboardInterrupt:
        remove_own_draft(ctx, tag, "interrupted")
    try:
        for attempt in range(VERIFY_TRIES):
            if attempt:
                ctx.clock.sleep(VERIFY_WAIT)
            problems = published_problems(ctx, tag, sha, local)
            if not problems:
                break
    except KeyboardInterrupt:
        problems = ["interrupted while checking"]
    if problems:
        raise Stop(EXIT_PUBLISHED_CHECK, "%s is published, but a check failed:\n  - %s\nNothing was deleted. Check %s/"
                   "releases/tag/%s, `gh api %sreleases/latest` and `git ls-remote %s refs/tags/%s` (expected %s)." % (
                       tag, "\n  - ".join(problems), WEB, tag, API, GIT_URL, tag, sha))
    ctx.say("publish: %s is public and latest, with both assets and their digests; the tag points at %s" % (tag, sha))
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
    start.add_argument("--new", action="store_true", help="start a new run in place of a failed one")
    collect.add_argument("--out", required=True)
    collect.add_argument("--timeout-min", type=int, default=100)
    publish.add_argument("--zip", required=True)
    publish.add_argument("--installer", required=True)
    publish.add_argument("--notes", required=True)
    smoke = sub.add_parser("smoke", parents=[common], help="start the post-release smoke run")
    smoke.add_argument("--version", required=True, type=_version)
    smoke.add_argument("--ref", default="main")
    return parser


COMMANDS = {"start": cmd_start, "collect": cmd_collect, "publish": cmd_publish, "smoke": cmd_smoke}


def main(argv=None, runner=run_process, clock=None, root=ROOT, out=None, err=None):
    args = build_parser().parse_args(argv)
    ctx = Context(runner, args.dry_run, clock or Clock(), Path(root), out or sys.stdout, err or sys.stderr)
    try:
        return COMMANDS[args.command](args, ctx)
    except Stop as stop:
        ctx.say("team_release %s: %s" % (args.command, stop))
        return stop.code
    except CallFailed as error:
        ctx.say("team_release %s: %s" % (args.command, error))
        return CALL_FAILURE_EXIT[args.command]


if __name__ == "__main__":
    sys.exit(main())
