<!-- Team fork release notes (both systems). Format follows v2.5.634.
Write in English. Replace every instruction comment with actual release content.
Keep all four sections; use 'None.' if a change category is empty.
Do not edit the Install / Upgrade block below except the Windows differences line:
`scripts/team_notes.py check` requires it, and `fill` replaces {{VERSION}} and
{{WINDOWS_SHA256}} after the Windows installer is verified. -->
## New

<!-- **Feature title** (#PR, @author) — explain the user-visible behavior. Say which system(s) it affects (Mac, Windows, both). -->

## Fixed

<!-- - Describe the resolved symptom (#PR, @author). One bullet per fix; sub-bullets for the user-visible consequence. -->

## Other

<!-- - Documentation, maintenance, or other changes. -->

## Contributors

<!-- Deduplicated GitHub handles, verified against every included PR and actual
human coauthor: @alice · @bob. Do not copy the previous release's list.
When there are none, write exactly: No external contributors in this release. -->

<!-- Add 'Thank you all.' below a nonempty contributor list. -->

---

**Mac Install:** `brew install --cask likelion-campus/tap/poke-token-bar-team`. See [TEAM.md](https://github.com/likelion-campus/PokeTokenBar/blob/main/TEAM.md).

**Mac Upgrade:** From v2.5.602 or later installed with Homebrew, the update button upgrades the app. From v2.5.601 or a zip install, run `brew install --cask likelion-campus/tap/poke-token-bar-team --force` once.

**Windows Install:** Download `PokeTokenBar-Setup-{{VERSION}}-win-x64.exe` below. Requires Windows 10 22H2 or Windows 11, x64. No administrator rights needed. The installer is not code-signed, so SmartScreen shows a warning: choose "More info", then "Run anyway".

**Windows Upgrade:** From v2.5.635 or later, the update button installs the new version and restarts the app. Earlier test builds run the installer once.

SHA-256 (Windows installer): {{WINDOWS_SHA256}}

**Windows differences:** <!-- List the popover differences from the Mac and the tier 3 status for this release. -->
