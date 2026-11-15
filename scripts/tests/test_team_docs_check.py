import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/team_docs_check.py"
MAC_SRC = "Sources/PokeTokenBar/UI/A.swift"
WIN_SRC = "Sources/PokeTokenBar/Platform/Windows/Popover/B.swift"
WIN_TRAY = "Sources/PokeTokenBar/Platform/Windows/WinTrayIcon.swift"
SHARED_SRC = "Sources/PokeTokenBar/Team/Plaza/C.swift"
MAC_IMG = "assets/screenshot-new.png"
WIN_IMG = "assets/windows/popover.png"
GOOD_SHOT = "popover.png | 123 | selftest --dump-ui | Sample-data capture, Windows CI runner\n"


class Repo:
    def __init__(self, d):
        self.d = Path(d)
        self.git("init", "-q")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")
        self.git("config", "commit.gpgsign", "false")
        self.write("README.md", "x")
        self.write("assets/windows/SHOTS.txt", "# header\n")
        self.write("assets/screenshot-old.png", "old")
        self.commit("chore: init")
        self.git("tag", "v1.0.0")

    def git(self, *a):
        subprocess.run(["git", *a], cwd=self.d, check=True, capture_output=True)

    def write(self, rel, text):
        p = self.d / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def commit(self, msg):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", msg)

    def check(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *args], cwd=self.d, capture_output=True, text=True)


class Gate(unittest.TestCase):
    def setUp(self):
        self._t = tempfile.TemporaryDirectory()
        self.addCleanup(self._t.cleanup)
        self.r = Repo(self._t.name)

    def test_no_change_passes(self):
        self.assertEqual(self.r.check().returncode, 0)

    def test_windows_feat_without_windows_asset_stops(self):
        self.r.write(WIN_SRC, "1")
        self.r.commit("feat(win): popover")
        res = self.r.check()
        self.assertEqual(res.returncode, 2, res.stderr)

    def test_windows_tray_glob_counts(self):
        self.r.write(WIN_TRAY, "1")
        self.r.commit("feat(win): tray")
        self.assertEqual(self.r.check().returncode, 2)

    def test_windows_feat_with_new_windows_asset_passes(self):
        self.r.write(WIN_SRC, "1")
        self.r.write(WIN_IMG, "png")
        self.r.write("assets/windows/SHOTS.txt", "# h\n" + GOOD_SHOT)
        self.r.commit("feat(win): popover")
        res = self.r.check()
        self.assertEqual(res.returncode, 0, res.stderr)

    def test_new_mac_asset_does_not_satisfy_windows(self):
        self.r.write(WIN_SRC, "1")
        self.r.write(MAC_IMG, "png")
        self.r.commit("feat(win): popover")
        self.assertEqual(self.r.check().returncode, 2)

    def test_mac_feat_needs_mac_asset_not_windows(self):
        self.r.write(MAC_SRC, "1")
        self.r.write(WIN_IMG, "png")
        self.r.write("assets/windows/SHOTS.txt", "# h\n" + GOOD_SHOT)
        self.r.commit("feat: mac ui")
        self.assertEqual(self.r.check().returncode, 2)
        self.r.write(MAC_IMG, "png")
        self.r.commit("docs: mac shot")
        self.assertEqual(self.r.check().returncode, 0)

    def test_shared_feat_needs_both_groups(self):
        self.r.write(SHARED_SRC, "1")
        self.r.write(MAC_IMG, "png")
        self.r.commit("feat(plaza): shared")
        self.assertEqual(self.r.check().returncode, 2)
        self.r.write(WIN_IMG, "png")
        self.r.write("assets/windows/SHOTS.txt", "# h\n" + GOOD_SHOT)
        self.r.commit("docs: windows shot")
        self.assertEqual(self.r.check().returncode, 0)

    def test_fix_only_warns(self):
        self.r.write(WIN_SRC, "1")
        self.r.write(MAC_SRC, "1")
        self.r.commit("fix: both")
        res = self.r.check()
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("WARNING", res.stderr)

    def test_redrawn_capture_is_not_added(self):
        self.r.write(WIN_IMG, "v1")
        self.r.write("assets/windows/SHOTS.txt", "# h\n" + GOOD_SHOT)
        self.r.commit("docs: shot")
        self.r.git("tag", "v1.0.1")
        self.r.write(WIN_SRC, "1")
        self.r.write(WIN_IMG, "v2 redrawn")
        self.r.commit("feat(win): popover")
        self.assertEqual(self.r.check().returncode, 2)

    def test_since_flag_overrides_tag(self):
        self.r.write(WIN_SRC, "1")
        self.r.commit("feat(win): popover")
        self.r.git("tag", "v1.0.1")
        self.assertEqual(self.r.check().returncode, 0)
        self.assertEqual(self.r.check("--since", "v1.0.0").returncode, 2)

    def test_feat_regex_variants(self):
        self.r.write(WIN_SRC, "1")
        self.r.commit("feature!: breaking")
        self.assertEqual(self.r.check().returncode, 2)

    def test_featured_prefix_is_not_feat(self):
        self.r.write(WIN_SRC, "1")
        self.r.commit("featureless: nothing")
        self.assertEqual(self.r.check().returncode, 0)


class Shots(unittest.TestCase):
    def setUp(self):
        self._t = tempfile.TemporaryDirectory()
        self.addCleanup(self._t.cleanup)
        self.r = Repo(self._t.name)

    def test_png_missing_from_shots_stops(self):
        self.r.write(WIN_IMG, "png")
        self.r.commit("docs: shot")
        res = self.r.check()
        self.assertEqual(res.returncode, 2)
        self.assertIn("not listed", res.stderr)

    def test_label_without_runner_stops(self):
        self.r.write(WIN_IMG, "png")
        self.r.write("assets/windows/SHOTS.txt", "popover.png | 1 | cmd | Sample-data capture\n")
        self.r.commit("docs: shot")
        res = self.r.check()
        self.assertEqual(res.returncode, 2)
        self.assertIn("Windows CI runner", res.stderr)

    def test_listed_file_missing_stops(self):
        self.r.write("assets/windows/SHOTS.txt", "# h\n" + GOOD_SHOT)
        self.r.commit("docs: shots")
        self.assertEqual(self.r.check().returncode, 2)

    def test_malformed_line_stops(self):
        self.r.write("assets/windows/SHOTS.txt", "popover.png | only | three\n")
        self.r.commit("docs: shots")
        self.assertEqual(self.r.check().returncode, 2)

    def test_valid_shots_passes(self):
        self.r.write(WIN_IMG, "png")
        self.r.write("assets/windows/SHOTS.txt", "# h\n" + GOOD_SHOT)
        self.r.commit("docs: shot")
        self.assertEqual(self.r.check().returncode, 0)

    def test_no_tag_is_usage_error_exit_1(self):
        self.r.git("tag", "-d", "v1.0.0")
        self.assertEqual(self.r.check().returncode, 1)


if __name__ == "__main__":
    unittest.main()
