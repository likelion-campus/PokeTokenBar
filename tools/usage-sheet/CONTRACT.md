# Usage report wire contract v1

The app POSTs one JSON body to the Apps Script web app.
Apps Script web apps answer a POST with a 302 redirect; the client must follow it with GET to read the JSON
body. The write is already done before the redirect. A body that is not JSON (an HTML error page from a
lock timeout or a quota) means the report failed. Retrying is safe: every write is idempotent per key.

## Request

```json
{
  "v": 1,
  "token": "996c41db62671eaf62a86cf3e18202ee",
  "member": { "id": "8F1C…-UUID", "secret": "base64url-or-hex, 32–128 chars",
              "nickname": "지아", "appVersion": "2.5.640", "platform": "mac" },
  "days": [
    { "date": "2026-11-16", "team": "t_ab12cd34ef56", "teamLabel": "팀 1",
      "tools": [ { "tool": "claude_code", "input": 1200, "output": 800,
                   "cacheWrite": 5000, "cacheRead": 90000 } ] }
  ],
  "limits": [
    { "tool": "claude", "account": "e_3f9a…", "domain": "likelion.net", "plan": "Max",
      "usedPercent": 82.5, "resetsAt": "2026-11-19T09:00:00Z",
      "readAt": "2026-11-16T10:00:00Z", "team": "t_ab12cd34ef56" }
  ]
}
```

## Envelope rules

A failure here rejects the whole request with `{"ok":false,"error":"<code>"}`.

| Field | Rule | Error code |
|---|---|---|
| body | at most 262144 bytes (UTF-8) | `too_large` |
| JSON | must parse to an object | `bad_json` |
| `v` | must be `1` | `bad_version` |
| `token` | must equal the shared token | `bad_token` |
| `member.id` | UUID, `/^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/` | `bad_member` |
| `member.secret` | `/^[A-Za-z0-9_-]{32,128}$/` | `bad_member` |
| `member.nickname` | after trimming: at least 1 character, at most 320 UTF-8 bytes, no newline. The app counts grapheme clusters (1–12); the script cannot, so it only bounds the size and trusts the app for the count | `bad_member` |
| `member.appVersion` | `/^[0-9A-Za-z.+-]{1,32}$/` | `bad_member` |
| `member.platform` | `mac` or `windows` | `bad_member` |
| `days` | an array of at most 21 entries (the app sends 21 at most: `UsageReportPlanner.dayRange`, unchanged since v2.5.636) | `too_many_rows` |
| `limits` | an array of at most 16 entries; omitted means `[]` | `too_many_rows` |
| tools | a day holds at most 32 | `too_many_rows` |

`days` or `limits` present but not an array is `bad_json`.

The shared token is public by design: it only turns away passing scanners. The script never stores a device secret, only its SHA-256 hex.

## Row rules

An invalid day, tool or limit entry is dropped and counted in `dropped`. The rest of the request still goes through.

- **`date`**
  - Matches `/^\d{4}-\d{2}-\d{2}$/` and is a real calendar date.
  - Lies between today − 400 days and today + 1 day, in the script's time zone.
- **`team`:** matches `/^t_[A-Za-z0-9_-]{2,62}$/` (days and limits alike). The prefix keeps an all-digit id from being turned into a number by Sheets.
- **`teamLabel`:** optional. When present it follows the nickname rule (non-empty, at most 320 bytes, no newline); an invalid label becomes `""` and does not drop the day.
- **`tools`**
  - Each `tool` id is one of the provider IDs the app sends (`ALLOWED_TOOLS` in `src/00_config.js`: `claude_code`, `codex`, `gemini`, `antigravity`, `grok`, `pi`, `omp`, `omo`, `kimi_code`, `opencode`, `hermes`, `cursor`, `copilot`, `devin`, `kiro`, `aside`). Any other id is dropped on its own. A new provider in the app needs its id added there, or its rows are dropped and counted in `dropped`.
  - Each of the four counts is an integer with `Number.isSafeInteger(n)` and `0 ≤ n ≤ 1e13`.
  - An invalid tool entry is dropped on its own.
  - A day with `tools: []` is valid. It records a zero row with tool `-`, so a member with no usage still appears.
  - A day whose non-empty `tools` list loses every entry is dropped too (one more in `dropped`). It never turns into a `-` row.
- **Duplicates:** a repeated `date|tool` within one payload keeps the last occurrence.
- **Limit fields**
  - `tool` is `claude` or `codex` (`ALLOWED_LIMIT_TOOLS`).
  - `account` matches `/^(e|m)_[A-Za-z0-9_-]{2,126}$/`: the prefix the app must use anyway (see App obligations). It keeps an all-digit or `1e5`-style id from being turned into a number by Sheets.
  - `domain` is `""` or matches `/^[a-z0-9.-]{1,253}$/`; it is lowercased first.
  - `plan` is 1–40 characters.
  - `usedPercent` is finite and between 0 and 1000.
  - `team` follows the team rule.
- **Formula-leading text:** a leading `=`, `+`, `-` or `@` in `nickname`, `teamLabel` or `plan` is replaced by its full-width twin (`＝ ＋ － ＠`) at parse time, so a CSV export cannot evaluate it and the text still reads the same. Only the first character changes.
- **Row identity:** a limit row is identified by `memberId|account|tool` plus its weekly window. A report updates the existing row of the same identity whose reset time is within 24 hours of the incoming one, otherwise it appends a row. A member can therefore only touch rows carrying its own `memberId`.
- **Limit times**
  - `resetsAt` and `readAt` must parse with `Date.parse`.
  - `resetsAt` lies within now ± 8 days.
  - `readAt` lies between now − 8 days and now + 10 minutes.
  - `resetsAt` is normalized to the nearest whole hour UTC (`…:00:00.000Z`), because the source jitters by seconds.

## Response

- success: `{"ok":true,"accepted":{"days":<rows written>,"limits":<rows written>},"dropped":<n>}`
- failure: `{"ok":false,"error":"<code>"}`

`device_mismatch` is the error code when a known `member.id` arrives with a different secret.

Intake limits (constants in `src/00_config.js`, table in the README) answer `{"ok":false,"error":"rate_limited"}` (a cap for this clock hour is used up) or `{"ok":false,"error":"sheet_full"}` (a total cap is reached). Both are "try again later" for the sender: the app logs any `ok:false`, commits nothing and resends at its next interval (unsent days stay inside its 21-day window).

The script plans every tab, checks every cap, and only then writes:

- A refusal on the **raw rows** (or on the member caps) refuses the whole request: nothing is written, not even the device registration.
- A refusal on the **limit rows** or on the **team rows** (`부서`, `팀이름`) does not refuse the request. The usage rows, the person row and the device row are written, the refused part is dropped, and the response is `ok:true`. A dropped limit list shows as `accepted.limits: 0` and adds its entries to `dropped`. The app commits the limits as sent; it sends each account again when the account's next reading is newer, so a dropped limit is replaced by the next reading. A dropped team list leaves the team's 부서 row missing until a later report (the raw rows still carry the team ID).
- Hourly caps are charged per member (a registered member is never blocked by another member's reports). The shared hourly pool is charged only for members first seen in the current clock hour, so a flood of fake members cannot use up what registered members need.

## App obligations (not checked by the script)

- When the email is known, `account` is `"e_"` plus the first 16 hex characters of the SHA-256 of the lowercased email. Otherwise it is `"m_" + member.id + "_" + localAccountId`.
- `team` is the app's team ID: an HMAC of the team code, truncated. It is a hash, not a secret: someone who can guess the code can match it. `account` (`e_...`) is likewise a hash of the email address, which anyone who can guess the address can match.

## Fixtures

`fixtures/*.json` hold example bodies with their expected outcome (`{description, body, expect}`). The app's tests can reuse them with `now = 2026-11-16T03:00:00Z` and time zone `Asia/Seoul`.
