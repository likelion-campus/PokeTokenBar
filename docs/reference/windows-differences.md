---
summary: "The maintained list of how the Windows build differs from the Mac app (popover, plaza, services), each with its reason, plus what is not on Windows yet."
read_when:
  - you change a Windows popover or plaza view, or add one (add or remove its line here)
  - you write release notes' "Windows differences" line or the Windows section of TEAM.md
  - a user asks "why does Windows look or behave differently here"
---

# Windows differences from the Mac

**The rule (user ruling, 2026-11-16):** the Mac app is the reference for Windows UI and behaviour. A difference is allowed
only for a concrete reason: a Windows convention users rely on, a capability the native control lacks, or an idle-cost
budget. "Simpler to build" is not a reason. Every difference lives in this file with its reason; a change that adds or
removes one edits this file in the same PR.

The popover is a native Win32 implementation (not SwiftUI); the rules and numbers it shows come from shared code
(`Sources/PokeTokenBar/Popover/`, twin-tested against the Mac views). The plaza is the same shared scene on both systems,
drawn by SpriteKit on the Mac and Direct2D on Windows. Captures of the Windows side are in `assets/windows/` (sample data,
made on the CI runner; provenance in `assets/windows/SHOTS.txt`). Sources of this list: the stage 7 reports of the popover
tasks and `parity-report.md` in the Windows port ledger.

Last reviewed against: the popover with Home, Settings, Recap, Shop, Bag, Collection and the Pokémon detail page, dark mode
and high contrast, the in-app update, the installer and the floating pet with its bubbles, hearts, prayers, hover readout
and agent reactions, and the `poketokenbar:` link.

## Approved by the user

| Difference | Reason |
|---|---|
| Home shows a one-line hint on a first run (no usage yet) | tells a new user what fills the page; the Mac shows an empty page |
| Relative times move in 30 s steps for the first minute, then each minute | idle budget: a one-second clock woke the app 81 times a minute |
| Update: one click installs (downloads, checks, runs Setup, the app restarts) | the Windows counterpart of `brew upgrade`; the first build with it is named in the release notes |
| Chart hover readout is a pop-up window above the chart; arrow keys select a day | a drawn part cannot float a view inside the popover; keyboard access |
| No placeholder text in multi-line edits | the Win32 multi-line edit has no cue banner |
| The password field's reveal control is Windows' eye glyph | the Mac's SF symbol does not exist |
| Light, dark and high contrast follow Windows (dark is shared state, not a Mac copy) | Windows conventions |
| Left click on the tray icon opens the popover, right click the menu | tray convention |
| The "Menu bar" settings group and the Keychain switch are hidden | no menu-bar text on Windows; no Keychain |
| Secrets use DPAPI; wording says "this PC", "Windows account" | the Windows counterpart of Keychain |
| A marquee bar where the Mac shows a small spinner | Win32 has no spinner control |
| Sprite bob moves in whole device pixels; wiggle in three poses | idle budget (sub-pixel at 60 Hz would wake the app 3600 times a minute) |
| System file and task dialogs, with Replace and Cancel | native dialogs; the popover stays open under an open dialog |
| Windows fonts, emoji and accent colour; no blur behind capsules and chevrons | Windows conventions; no cheap vibrancy |
| Tertiary text opacity is the Mac's value, to be reviewed on a real screenshot | pending the user's screenshot |

## Controls

| Difference | Reason |
|---|---|
| Check boxes instead of switches | Win32 has no switch control |
| "Used / Remaining", "Week / Month / Year" are push-like radio buttons; pickers are combo boxes or popup buttons | no native segmented or menu picker; the scope group has no accessible group name (a radio group is named by a group box) |
| Provider and account tabs wrap onto several lines when they do not fit | the kit has no horizontal scroller |
| Bordered buttons are native push buttons; Skip, Update, Details, the tabs and Back are drawn by the kit as pills | the native button has no borderless, capsule or prominent look |
| The footer's error triangle is a focusable button (its message is its accessible name) | screen readers |
| A thin scroll thumb in a 12 pt lane in drawn lists (catch log, Pokémon detail), drawn only while the list is longer than its window but then always (the Mac's appears while scrolling) | a fade needs a timer after every scroll; the idle budgets allow none |
| The page's scroll bar is the system's, on the screen only while the page is taller than its window (Mac: an overlay scroller drawn while scrolling); the lane beside the content stays empty either way, so the layout never shifts. The catch log and the Pokémon detail page have one scroller each (their own thumb), the page bar is not shown there | an overlay scroller would be a custom-drawn control without the system bar's keyboard and accessibility behaviour |
| Loading shows text without a spinner (Pokémon detail) | no timer for a spinner |
| Search field: a separate clear button, no magnifier icon | a native `EDIT` has a cue banner instead of embedded icons |
| Stepper and Buy/Use buttons are native controls; the stepper field is wider | native look |
| Pokédex grid cell height is what the 520 pt page leaves (about 89 pt, Mac about 91) | fixed page height |
| Grid cells take arrow keys and Page Up/Down; chip rows scroll with Shift+wheel or a horizontal wheel | keyboard access; no trackpad swipe |

## Look

| Difference | Reason |
|---|---|
| Header digits are the drawn font's own, not tabular | the renderer has no tabular-digit switch |
| Recap card: the shell gradient is 1 px stripes and the lens gradient discs, no LCD corner glow, weight 500 drawn semibold; the card is 320 wide (Mac 332) | the shared canvas has no gradients; the scroll area always reserves its lane |
| `.regularMaterial` plates (the +XP capsule, number tags, chevron circles) are light translucent fills | no blur |
| Evolution line: chevrons appear without the 0.15 s fade; arrows are Segoe Fluent E72A; the "?" node is Pretendard Bold; the egg emoji is orange, not cream | fonts and glyph tables |
| The Mac's shadow in hover states is the canvas shadow (blur 4, y 2) | the canvas has one shadow model |
| Empty Bag keeps the 520 pt content area; the Mac's popover shrinks | resizing on a tab switch would make the window jump |
| Texts that are `lineLimit` on the Mac wrap instead of being cut | no truncation model on the kit's labels |

## Behaviour

| Difference | Reason |
|---|---|
| Windows' "Show animations" switch stops GIFs, bob, wiggle and celebrations; the Mac popover animates whatever Reduce Motion says | Windows setting |
| Windows' text size scales the header text | the Mac has no system text size |
| Chart day hover target is the whole column height | tiny bars were hard to hit |
| Advanced: the folders' "found" count waits 250 ms and is counted off the main thread | a network share can take seconds |
| A rebuild of the page (language, DPI, new saved team) clears a typed-but-unsaved session key | the safe direction for a secret |
| Credential help and storage notes use Windows wording (the Claude sign-in file, DPAPI) | the Mac's text mentions Keychain |
| Import and export: the file filter is labelled "Save file (*.json)"; confirmations say "this PC / another computer" | Windows dialogs; wording |
| Growth bar, evolution line and the egg wiggle follow the Mac (since #245); animation is in steps where the budget needs it | idle budget |

## Services

| Mac | Windows |
|---|---|
| Keychain (OAuth login, session key) | the Claude sign-in file and session key encrypted with DPAPI |
| Homebrew cask; the update button runs `brew` | GitHub release asset `PokeTokenBar-Setup-<version>-win-x64.exe`, installed per user, unsigned |
| User notifications | tray balloons |
| ServiceManagement login item | `HKCU\...\Run` value (removed by Uninstall when it starts this install) |
| Bonjour (`NWBrowser`) | Windows DNS-SD; the same service name, key derivation and frames, so Mac and Windows teammates meet; the firewall asks once (choose Private) |
| `~/Library/Application Support/PokeTokenBar` | `%LOCALAPPDATA%\PokeTokenBar` (state, settings, logs); kept by Uninstall |
| Gatekeeper warning on first open | SmartScreen warning on first run |

## The floating pet (stage 7 Tasks 22 and 23)

| Difference | Reason |
|---|---|
| A saved place whose monitor is gone shows the pet in the default corner and is kept; the pet returns when the monitor does (the Mac saves the corner) | user ruling 2026-11-18: a monitor away for a moment (a dock, a projector) must not lose the place |
| A move onto a monitor of another scale keeps the pet's size until the drag ends, then takes the new size; otherwise it goes where Windows suggests | Windows only: per-monitor DPI (the Mac's points are the same on every screen); growing in place at a mixed-DPI edge could flip sizes without end |
| With the popover open, a press on the pet closes it when the press ends (a click, or the drop of a drag); the Mac closes it when the press starts | Win32: closing the active popover while the button is down moves the foreground away and ends the pet's mouse capture, so the prayer or the drag would be lost |
| After the pet's right-click menu (Escape, Back view, Turn off) the window that had the keyboard gets it back | the pet never takes the foreground, but a Win32 menu must; the Mac leaves the app active |
| Large sizes are scaled by the app (the shared smooth filter): at 192 and 384 slightly crisper than the Mac | a layered window takes finished pixels; Core Animation scales on the Mac |
| The speech bubble and the hover readout are set in the popover's Windows fonts: the Mac's cut rule (titles to one line, the body to two, the account dropped first) over Windows' measurements, so a line may break at another word | the fonts differ; the cut rule is shared and tested against the Mac's own measurement |
| The bubble's second line and the readout take the popover's colours: Windows' readable secondary text (0.68 light, 0.72 dark) and, in dark mode, Windows' dark window (#202020; the Mac's is #1E1E1E) | the popover's contrast rule (approved by the user, 2026-11-17), so the app reads the same everywhere |
| The pet's hover tooltip is Windows' tooltip (after 600 ms, as the popover's, dark in dark mode) | Win32's own tooltip control; the Mac shows AppKit's help tag |
| A run to the pointer on a monitor of another scale keeps the pet's size on the way and takes that monitor's size when it arrives | per-monitor DPI, as for a drag |
| While the hearts show, a screen reader reads them as the pet window's name | the pet is one layered window with no accessible parts; the Mac labels the hearts' view |
| A `poketokenbar:` link longer than 8,192 characters is ignored (the Mac reads any length and then cuts the message and label) | a second start hands the link over as a message any local program could send: its copy is bounded. The longest link the pet can show, percent-encoded, is about 5,000 (5,042) |
| A link opened while the app is off starts it quietly and clean (no popover, none of the opener's arguments or environment, out of the opener's job where the job allows it); an elevated opener starts nothing; a link whose command line has anything more than the link (a quote that broke out) is dropped whole | Windows starts the handler with the opener's job, integrity level and environment, and with whatever the link's text splices into the command line; the Mac's Launch Services starts the app on its own |
| Another program of the same user can send the app links over `WM_COPYDATA`, or make a window of the app's class and title to take links meant for it | it already has the user's rights (the Mac's Apple events are open to it the same way); a message that is not a whole, tagged, valid UTF-16 link (a lone surrogate included) is refused, never a crash |
| The hook example checks `Get-Process PokeTokenBar` and opens the link with `Start-Process` (TEAM.md) | the Mac's uses `pgrep` and `open -g`; the rule is the same: a link opened while the app is off starts it and the event is dropped, so hooks check first |

## The plaza on the Mac changed too

Because the HUD panels are shared (stage 6, decision of 2026-11-15), Mac users see: no elastic scroll at the ends; a drawn
scroll indicator (appears while scrolling, fades after 0.7 s, always visible with the system's "always show" setting); a
mouse-wheel notch is 10 pt; colour emoji are drawn at one device pixel; text and shadow edges antialias slightly
differently; the roster's icons bounce together on one beat; card rarity colours follow the window's light/dark setting.

## Not on Windows yet (owed)

- **A capture of the floating pet on a plain desktop** (the runner's shows its terminal behind it). The pet, its
  bubbles, hearts, prayers, hover readout, agent reactions and the `poketokenbar:` link landed (stage 7 Tasks 22 and 23,
  differences above; captures `floating-pet.png`, `home-pet-eye-en.png`).
- **ARM64 native build** (the x64 build runs under emulation on Windows 11 on ARM, untested); **Windows 10** is untested.
- **Code signing:** the installer and the app are unsigned; SmartScreen warns on first run.
- **Captures owed:** tray menu with an update offer, the Setup welcome page, dark and high-contrast popover pages, Settings in
  Japanese, Mac renders of the roster, board and card panels.
