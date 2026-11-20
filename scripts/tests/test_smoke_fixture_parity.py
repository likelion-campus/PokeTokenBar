"""The post-release smoke runs the installed app's selftest. It must give that selftest the same fixture environment
windows-app.yml gives it (the windows-slice action makes it), or checks fail for want of a fixture, not a defect."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ACTION = (ROOT / ".github/actions/windows-slice/action.yml").read_text()
SMOKE = (ROOT / "scripts/windows/release-smoke.ps1").read_text()
# Written by the action but not needed by the smoke: PTB_FIXTURE is the smoke's own folder, the versions are stamped by the build job.
NOT_NEEDED = {"PTB_FIXTURE", "PTB_VERSION", "PTB_NEXT_VERSION", "PTB_BUILD_SHA256"}


class SmokeFixtureParity(unittest.TestCase):
    def test_smoke_sets_every_selftest_variable_the_slice_action_exports(self):
        exported = set(re.findall(r'"(PTB_[A-Z_]+)=', ACTION)) - NOT_NEEDED
        self.assertIn("PTB_SELFTEST_SPRITES", exported)  # guards the regex itself
        for name in sorted(exported):
            self.assertIn(f"$env:{name}", SMOKE, f"release-smoke.ps1 does not set {name}, which windows-slice gives the installed selftest")

    def test_smoke_fetches_the_sprites_the_way_the_slice_action_does(self):
        self.assertIn("fetch-fixture-sprites.ps1", ACTION)
        self.assertIn("fetch-fixture-sprites.ps1", SMOKE)


if __name__ == "__main__":
    unittest.main()
