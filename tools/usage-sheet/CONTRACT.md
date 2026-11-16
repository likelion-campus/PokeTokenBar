# Usage report wire contract v1

The app POSTs one JSON body to the Apps Script web app. The response is always HTTP 200 JSON.

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
| `member.nickname` | after trimming, 1–12 characters, no newline (the app's `validNickname`) | `bad_member` |
| `member.appVersion` | `/^[0-9A-Za-z.+-]{1,32}$/` | `bad_member` |
| `member.platform` | `mac` or `windows` | `bad_member` |
| `days` | an array of at most 62 entries | `too_many_rows` |
| `limits` | an array of at most 16 entries; omitted means `[]` | `too_many_rows` |
| tools | a day holds at most 32 | `too_many_rows` |

`days` or `limits` present but not an array is `bad_json`.

The shared token is public by design: it only turns away passing scanners. The script never stores a device secret, only its SHA-256 hex.

## Row rules

An invalid day, tool or limit entry is dropped and counted in `dropped`. The rest of the request still goes through.

- **`date`**
  - Matches `/^\d{4}-\d{2}-\d{2}$/` and is a real calendar date.
  - Lies between today − 400 days and today + 1 day, in the script's time zone.
- **`team`:** matches `/^[A-Za-z0-9_-]{4,64}$/`.
- **`teamLabel`:** optional. When present it follows the nickname rule; an invalid label becomes `""` and does not drop the day.
- **`tools`**
  - Each `tool` id matches `/^[a-z0-9_.-]{1,32}$/`.
  - Each of the four counts is an integer with `Number.isSafeInteger(n)` and `0 ≤ n ≤ 1e13`.
  - An invalid tool entry is dropped on its own.
  - A day with `tools: []` is valid. It records a zero row with tool `-`, so a member with no usage still appears.
  - A day whose non-empty `tools` list loses every entry is dropped too (one more in `dropped`). It never turns into a `-` row.
- **Duplicates:** a repeated `date|tool` within one payload keeps the last occurrence.
- **Limit fields**
  - `tool` uses the tool rule.
  - `account` matches `/^[A-Za-z0-9_-]{4,128}$/`.
  - `domain` is `""` or matches `/^[a-z0-9.-]{1,253}$/`; it is lowercased first.
  - `plan` is 1–40 characters.
  - `usedPercent` is finite and between 0 and 1000.
  - `team` follows the team rule.
- **Limit times**
  - `resetsAt` and `readAt` must parse with `Date.parse`.
  - `resetsAt` lies within now ± 8 days.
  - `readAt` lies between now − 8 days and now + 10 minutes.
  - `resetsAt` is normalized to the nearest whole hour UTC (`…:00:00.000Z`), because the source jitters by seconds.

## Response

- success: `{"ok":true,"accepted":{"days":<rows written>,"limits":<rows written>},"dropped":<n>}`
- failure: `{"ok":false,"error":"<code>"}`

`device_mismatch` is the error code when a known `member.id` arrives with a different secret.

## App obligations (not checked by the script)

- When the email is known, `account` is `"e_"` plus the first 16 hex characters of the SHA-256 of the lowercased email. Otherwise it is `"m_" + member.id + "_" + localAccountId`.
- `team` is the app's one-way team ID.

## Fixtures

`fixtures/*.json` hold example bodies with their expected outcome (`{description, body, expect}`). The app's tests can reuse them with `now = 2026-11-16T03:00:00Z` and time zone `Asia/Seoul`.
