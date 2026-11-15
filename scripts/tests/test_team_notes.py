import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("team_notes", ROOT / "scripts/team_notes.py")
tn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tn)
TEMPLATE = (ROOT / "docs/reference/team-release-notes-template.md").read_text(encoding="utf-8")

# the template's comments removed and the four sections filled
GOOD = TEMPLATE.replace("## New\n", "## New\n\nNone.\n", 1).replace("## Fixed\n", "## Fixed\n\nNone.\n", 1) \
    .replace("## Other\n", "## Other\n\nNone.\n", 1) \
    .replace("## Contributors\n", "## Contributors\n\nNo external contributors in this release.\n", 1)
SHA = "ab" * 32


class Check(unittest.TestCase):
    def test_filled_template_passes(self):
        self.assertEqual(tn.problems(GOOD), [])

    def test_raw_template_fails_on_empty_sections(self):
        found = tn.problems(TEMPLATE)
        self.assertEqual(len([f for f in found if "is empty" in f]), 4)

    def test_each_section_must_be_nonempty(self):
        for name in tn.SECTIONS:
            body = {"New": "None.", "Fixed": "None.", "Other": "None.",
                    "Contributors": "No external contributors in this release."}[name]
            text = GOOD.replace(f"## {name}\n\n{body}\n", f"## {name}\n\n<!-- c -->\n", 1)
            self.assertTrue(any(f"'## {name}' is empty" in f for f in tn.problems(text)), name)

    def test_missing_section_fails(self):
        self.assertTrue(any("'## Fixed'" in f for f in tn.problems(GOOD.replace("## Fixed\n", "", 1))))

    def test_windows_lines_each_required(self):
        for marker in tn.WINDOWS_LINES:
            text = GOOD.replace(marker, "**Renamed:**")
            self.assertTrue(any(marker in f for f in tn.problems(text)), marker)

    def test_windows_line_twice_fails(self):
        self.assertTrue(tn.problems(GOOD + "\n**Windows Install:** again\n"))

    def test_token_missing_or_duplicated_fails(self):
        for token in tn.TOKENS:
            self.assertTrue(any(token in f for f in tn.problems(GOOD.replace(token, "x"))))
            self.assertTrue(any(token in f for f in tn.problems(GOOD + "\n" + token + "\n")))

    def test_token_inside_comment_does_not_count(self):
        text = GOOD + "\n<!-- {{VERSION}} -->\n"
        self.assertEqual(tn.problems(text), [])

    def test_cli_exit_codes(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "n.md"
            f.write_text(GOOD)
            run = lambda: subprocess.run([sys.executable, str(ROOT / "scripts/team_notes.py"), "check", "--in", str(f)],
                                         capture_output=True, text=True)
            self.assertEqual(run().returncode, 0)
            f.write_text(TEMPLATE)
            r = run()
            self.assertEqual(r.returncode, 1)
            self.assertIn("is empty", r.stderr)


class Fill(unittest.TestCase):
    def run_fill(self, text, version="2.6.0", sha=SHA):
        with tempfile.TemporaryDirectory() as d:
            src, out = Path(d) / "n.md", Path(d) / "out.md"
            src.write_text(text)
            r = subprocess.run([sys.executable, str(ROOT / "scripts/team_notes.py"), "fill", "--in", str(src),
                                "--version", version, "--sha256", sha, "--out", str(out)],
                               capture_output=True, text=True)
            return r, (out.read_text() if out.exists() else None)

    def test_fill_replaces_tokens_and_drops_comments(self):
        r, out = self.run_fill(GOOD)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("PokeTokenBar-Setup-2.6.0-win-x64.exe", out)
        self.assertIn(f"SHA-256 (Windows installer): {SHA}", out)
        self.assertNotIn("{{", out)
        self.assertNotIn("<!--", out)

    def test_fill_refuses_leftover_token(self):
        r, out = self.run_fill(GOOD + "\n{{OTHER}}\n")
        self.assertEqual(r.returncode, 1)
        self.assertIn("leftover", r.stderr)
        self.assertIsNone(out)

    def test_fill_refuses_bad_sha(self):
        r, out = self.run_fill(GOOD, sha="zz")
        self.assertEqual(r.returncode, 1)
        self.assertIsNone(out)


if __name__ == "__main__":
    unittest.main()
