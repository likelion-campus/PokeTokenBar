"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { loadScript, DEFAULT_NOW_MS } = require("./harness.js");

const TZ = "Asia/Seoul";
const NOW = DEFAULT_NOW_MS; // 2026-11-16T03:00:00Z
const fixtureDir = path.join(__dirname, "..", "fixtures");
const MEMBER = "8F1C2A4E-3B5D-4C6E-9A7B-1D2E3F4A5B6C";

function validBody() {
  return JSON.parse(fs.readFileSync(path.join(fixtureDir, "valid-basic.json"), "utf8")).body;
}
// Values built inside the vm context have foreign prototypes; compare through JSON.
function plain(v) { return JSON.parse(JSON.stringify(v)); }
function fresh() {
  const S = loadScript();
  return { S, ss: S.fakes.ss };
}
function report(S, body, nowMs) {
  return plain(S.handleReport(S.fakes.ss, JSON.stringify(body), nowMs === undefined ? NOW : nowMs, TZ));
}
function dataRows(ss, tab) {
  return ss.getSheetByName(tab)._rows.slice(1);
}
function scriptLock(S) { const { acquired, released, held } = plain(S.fakes.lockStats); return { acquired, released, held }; }
function snapshot(ss) {
  return JSON.stringify(ss.getSheets().map((s) => [s.getName(), s._rows]));
}
function limitBody(usedPercent, resetsAt, readAt) {
  const b = validBody();
  b.days = [];
  b.limits[0].usedPercent = usedPercent;
  b.limits[0].resetsAt = resetsAt;
  b.limits[0].readAt = readAt;
  return b;
}

test("valid-basic into an empty spreadsheet", () => {
  const { S, ss } = fresh();
  const r = report(S, validBody());
  assert.deepEqual(r, { ok: true, accepted: { days: 3, limits: 1 }, dropped: 0 });
  assert.equal(dataRows(ss, "원본").length, 3);
  assert.equal(dataRows(ss, "한도").length, 1);
  assert.equal(dataRows(ss, "사람").length, 1);
  assert.equal(dataRows(ss, "기기").length, 1);
  const depts = dataRows(ss, "부서");
  assert.equal(depts.length, 1);
  assert.equal(depts[0][0], "t_ab12cd34ef56");
  assert.equal(depts[0][2], "팀 1");
  assert.equal(depts[0][3], "2026-11-16");
  const raw = dataRows(ss, "원본");
  assert.equal(raw[0][9], 1200 + 800 + 5000 + 90000);
  assert.equal(raw[0][12], new Date(NOW).toISOString());
  assert.equal(raw[2][3], "-");
});

test("the same keys again overwrite the numbers in place", () => {
  const { S, ss } = fresh();
  report(S, validBody());
  const b = validBody();
  b.days[0].tools[0].input = 7;
  b.days[0].tools[0].output = 0;
  b.days[0].tools[0].cacheWrite = 0;
  b.days[0].tools[0].cacheRead = 0;
  report(S, b, NOW + 60000);
  assert.equal(dataRows(ss, "원본").length, 3);
  assert.equal(dataRows(ss, "한도").length, 1);
  assert.equal(dataRows(ss, "사람").length, 1);
  assert.equal(dataRows(ss, "기기").length, 1);
  assert.equal(dataRows(ss, "부서").length, 1);
  const row = dataRows(ss, "원본")[0];
  assert.equal(row[5], 7);
  assert.equal(row[9], 7);
  assert.equal(row[12], new Date(NOW + 60000).toISOString());
});

test("another secret for a known member is device_mismatch and writes nothing", () => {
  const { S, ss } = fresh();
  report(S, validBody());
  const before = snapshot(ss);
  const b = validBody();
  b.member.secret = "b3RoZXItc2VjcmV0LWZvci1maXh0dXJlcy1vbmx5LTAwMDA";
  b.days[0].tools[0].input = 999;
  const r = report(S, b, NOW + 60000);
  assert.deepEqual(r, { ok: false, error: "device_mismatch" });
  assert.equal(snapshot(ss), before);
});

test("the device tab stores a 64-char lowercase hex hash, never the secret", () => {
  const { S, ss } = fresh();
  const b = validBody();
  report(S, b);
  const row = dataRows(ss, "기기")[0];
  assert.match(row[1], /^[0-9a-f]{64}$/);
  assert.equal(JSON.stringify(ss.getSheets().map((s) => s._rows)).includes(b.member.secret), false);
  report(S, b, NOW + 5000);
  const again = dataRows(ss, "기기")[0];
  assert.equal(again[2], new Date(NOW).toISOString());
  assert.equal(again[3], new Date(NOW + 5000).toISOString());
});

test("a rejected payload writes no data rows", () => {
  const { S, ss } = fresh();
  const b = validBody();
  b.token = "nope";
  assert.deepEqual(report(S, b), { ok: false, error: "bad_token" });
  assert.deepEqual(ss.getSheets().map((x) => x.getName()), ["시트1"]);   // rejected before any tab is created
});

test("limit max and last usage, with a later read", () => {
  const { S, ss } = fresh();
  report(S, limitBody(82, "2026-11-19T09:00:00Z", "2026-11-16T01:00:00Z"));
  report(S, limitBody(60, "2026-11-19T09:00:00Z", "2026-11-16T02:00:00Z"));
  const rows = dataRows(ss, "한도");
  assert.equal(rows.length, 1);
  assert.equal(rows[0][7], 82);
  assert.equal(rows[0][8], 60);
  assert.equal(rows[0][9], "2026-11-16T02:00:00.000Z");
});

test("an older readAt arriving later changes only the max", () => {
  const { S, ss } = fresh();
  report(S, limitBody(60, "2026-11-19T09:00:00Z", "2026-11-16T02:00:00Z"));
  const b = limitBody(90, "2026-11-19T09:00:00Z", "2026-11-16T01:00:00Z");
  b.limits[0].plan = "Pro";
  report(S, b);
  const rows = dataRows(ss, "한도");
  assert.equal(rows.length, 1);
  assert.equal(rows[0][7], 90);
  assert.equal(rows[0][8], 60);
  assert.equal(rows[0][9], "2026-11-16T02:00:00.000Z");
  assert.equal(rows[0][5], "Max");
});

test("resetsAt jitter of 40 seconds stays one limit row", () => {
  const { S, ss } = fresh();
  report(S, limitBody(50, "2026-11-19T08:59:40Z", "2026-11-16T01:00:00Z"));
  report(S, limitBody(55, "2026-11-19T09:00:20Z", "2026-11-16T02:00:00Z"));
  assert.equal(dataRows(ss, "한도").length, 1);
});

test("owner-edited columns survive later reports", () => {
  const { S, ss } = fresh();
  report(S, validBody());
  ss.getSheetByName("부서")._rows[1][1] = "개발부";
  ss.getSheetByName("사람")._rows[1][3] = "other-member";
  const b = validBody();
  b.member.nickname = "새닉";
  report(S, b, NOW + 60000);
  assert.equal(dataRows(ss, "부서")[0][1], "개발부");
  const p = dataRows(ss, "사람")[0];
  assert.equal(p[3], "other-member");
  assert.equal(p[1], "새닉");
});

test("team labels upsert only when non-empty", () => {
  const { S, ss } = fresh();
  report(S, validBody());
  assert.equal(dataRows(ss, "팀이름").length, 1);
  assert.deepEqual(plain(dataRows(ss, "팀이름")[0].slice(0, 3)), ["t_ab12cd34ef56", MEMBER, "팀 1"]);
  const b = validBody();
  b.days.forEach((d) => { d.teamLabel = ""; });
  report(S, b, NOW + 1000);
  assert.equal(dataRows(ss, "팀이름").length, 1);
  assert.equal(dataRows(ss, "팀이름")[0][2], "팀 1");
});

test("the lock is taken and released once per call, also on a throw", () => {
  const { S, ss } = fresh();
  report(S, validBody());
  assert.deepEqual(scriptLock(S), { acquired: 1, released: 1, held: false });
  report(S, { v: 2 });   // parsed before the lock: no lock taken
  assert.deepEqual(scriptLock(S), { acquired: 1, released: 1, held: false });
  ss.getSheetByName("원본").getRange = () => { throw new Error("boom"); };
  assert.throws(() => S.handleReport(ss, JSON.stringify(validBody()), NOW + 1, TZ), /boom/);
  assert.deepEqual(scriptLock(S), { acquired: 2, released: 2, held: false });
});

test("ensureSheets is idempotent, hides two tabs and sets text format on date columns", () => {
  const { S, ss } = fresh();
  S.ensureSheets(ss);
  const snap = snapshot(ss);
  S.ensureSheets(ss);
  assert.equal(snapshot(ss), snap);
  assert.deepEqual(ss.getSheets().map((s) => s.getName()), ["시트1", "원본", "한도", "사람", "부서", "팀이름", "기기", "설정", "엔터프라이즈 원본", "엔터프라이즈 사람", "엔터프라이즈기록"]);
  assert.equal(ss.getSheetByName("팀이름").isSheetHidden(), true);
  assert.equal(ss.getSheetByName("기기").isSheetHidden(), true);
  assert.equal(ss.getSheetByName("원본").isSheetHidden(), false);
  assert.equal(ss.getSheetByName("설정")._rows.length, 11);
  assert.deepEqual(plain(ss.getSheetByName("원본")._rows[0]), plain(S.COLS_RAW));
  assert.equal(ss.getSheetByName("원본")._formats[3], "@");
  assert.deepEqual([3, 10].map((c) => ss.getSheetByName("한도")._formats[c]), ["@", "@"]);
  assert.equal(ss.getSheetByName("부서")._formats[4], "@");
});

test("ensureSheets keeps the settings value column as text", () => {
  const { S, ss } = fresh();
  S.ensureSheets(ss);
  assert.equal(ss.getSheetByName("설정")._formats[2], "@");
});

test("reports pushing the raw tab past the 1000-row grid still land", () => {
  const { S, ss } = fresh();
  function big(firstDay) {
    const b = validBody();
    b.limits = [];
    b.days = [];
    for (let d = firstDay; d < firstDay + 62; d++) {
      const date = S.localDateString(NOW - d * 86400000, TZ);
      b.days.push({ date, team: "t_ab12cd34ef56", tools: S.ALLOWED_TOOLS.map((tool) => (
        { tool, input: 1, output: 1, cacheWrite: 1, cacheRead: 1 })) });
    }
    return b;
  }
  assert.equal(report(S, big(0)).ok, true);
  assert.equal(dataRows(ss, "원본").length, 992);
  assert.equal(report(S, big(62), NOW + 1000).ok, true);
  assert.equal(dataRows(ss, "원본").length, 1984);
  assert.equal(ss.getSheetByName("원본").getMaxRows() >= 1985, true);
});

test("the device tab grows past 1000 members", () => {
  const { S, ss } = fresh();
  S.ensureSheets(ss);
  const dev = ss.getSheetByName("기기");
  for (let i = 0; i < 999; i++) dev._rows.push([`m${i}`, "h", "", ""]);
  const r = report(S, validBody());
  assert.equal(r.ok, true);
  assert.equal(dataRows(ss, "기기").length, 1000);
});

test("ensureSheets does not rewrite settings the owner edited", () => {
  const { S, ss } = fresh();
  S.ensureSheets(ss);
  ss.getSheetByName("설정")._rows[2][1] = 55;
  S.ensureSheets(ss);
  assert.equal(ss.getSheetByName("설정")._rows[2][1], 55);
});

test("cellToDateString accepts a Date and a string", () => {
  const { S } = fresh();
  assert.equal(S.cellToDateString(new Date("2026-11-16T00:00:00+09:00"), TZ), "2026-11-16");
  assert.equal(S.cellToDateString(" 2026-11-16 ", TZ), "2026-11-16");
  assert.equal(S.cellToDateString(5, TZ), "");
  assert.equal(S.cellToDateString("", TZ), "");
});

test("parseSettings falls back to defaults on bad values", () => {
  const { S } = fresh();
  for (const bad of ["", "abc", -5, "-5", null, "NaN", "Infinity"]) {
    const s = plain(S.parseSettings([["forecast_fit_pct", bad]]));
    assert.equal(s.forecast_fit_pct, 70, `value ${JSON.stringify(bad)}`);
  }
  assert.equal(S.parseSettings([["forecast_fit_pct", "70%"]]).forecast_fit_pct, 70);
  assert.equal(S.parseSettings([["forecast_fit_pct", "55%"]]).forecast_fit_pct, 55);
  assert.equal(S.parseSettings([["min_pace", "0.25"]]).min_pace, 0.25);
  assert.equal(S.parseSettings([]).forecast_short_pct, 100);
  assert.deepEqual(plain(S.parseSettings([["plan_order_claude", "Pro , Max,Ultra"]]).plan_order_claude), ["Pro", "Max", "Ultra"]);
  assert.deepEqual(plain(S.parseSettings([]).plan_order_codex), ["plus", "pro"]);
  assert.deepEqual(plain(S.parseSettings([["plan_order_codex", ""]]).plan_order_codex), ["plus", "pro"]);
});

test("parseSettings ignores unknown keys, including __proto__", () => {
  const { S } = fresh();
  const s = S.parseSettings([["__proto__", 5], ["whatever", 1], ["stale_hours", 12]]);
  assert.equal(s.stale_hours, 12);
  assert.equal(s.whatever, undefined);
  assert.equal(s.polluted, undefined);
});

test("readAll normalizes dates and numbers", () => {
  const { S, ss } = fresh();
  report(S, validBody());
  report(S, limitBody(82.5, "2026-11-19T09:00:00Z", "2026-11-16T02:00:00Z"));
  // The owner retypes cells and Sheets turns the text into Dates.
  ss.getSheetByName("원본")._rows[1][2] = new Date("2026-11-15T00:00:00+09:00");
  ss.getSheetByName("한도")._rows[1][2] = new Date("2026-11-19T09:00:00Z");
  ss.getSheetByName("한도")._rows[1][9] = new Date("2026-11-16T02:00:00Z");
  const a = S.readAll(ss, TZ);
  assert.equal(a.usage.length, 3);
  assert.deepEqual(plain(a.usage[0]), { memberId: MEMBER, date: "2026-11-15", tool: "claude_code", team: "t_ab12cd34ef56", total: 97000 });
  assert.equal(a.limits.length, 1);
  assert.equal(a.limits[0].resetsAt, Date.parse("2026-11-19T09:00:00Z"));
  assert.equal(a.limits[0].lastReadAt, Date.parse("2026-11-16T02:00:00Z"));
  assert.equal(a.limits[0].maxUsed, 82.5);
  assert.equal(a.limits[0].account, "e_3f9a1c2b4d5e6f70");
  assert.equal(a.limits[0].domain, "likelion.net");
  assert.equal(a.people[MEMBER].nickname, "지아");
  assert.equal(a.people[MEMBER].mergeInto, "");
  assert.deepEqual(plain(a.depts["t_ab12cd34ef56"]), { name: "", suggested: "팀 1" });
  assert.deepEqual(plain(a.teamLabels), [{ team: "t_ab12cd34ef56", memberId: MEMBER, label: "팀 1" }]);
  assert.equal(a.settings.forecast_fit_pct, 70);
});

test("a retyped Date cell in the raw tab is still the same key on the next report", () => {
  const { S, ss } = fresh();
  report(S, validBody());
  ss.getSheetByName("원본")._rows[1][2] = new Date("2026-11-15T00:00:00+09:00");
  report(S, validBody(), NOW + 1000);
  assert.equal(dataRows(ss, "원본").length, 3);
});

test("readAll on empty tabs", () => {
  const { S, ss } = fresh();
  const a = S.readAll(ss, TZ);
  assert.deepEqual(plain(a.usage), []);
  assert.deepEqual(plain(a.limits), []);
  assert.deepEqual(plain(a.people), {});
  assert.deepEqual(plain(a.depts), {});
  assert.equal(a.settings.suggest_weeks, 4);
});

test("doPost returns JSON text", () => {
  const { S } = fresh();
  const out = S.doPost({ postData: { contents: JSON.stringify(validBody()) } });
  assert.equal(out.getMimeType(), "JSON");
  assert.equal(JSON.parse(out.getContent()).ok, true);
});

test("doPost without postData is bad_json", () => {
  const { S } = fresh();
  assert.deepEqual(JSON.parse(S.doPost({}).getContent()), { ok: false, error: "bad_json" });
});

test("doGet says ok", () => {
  const { S } = fresh();
  assert.equal(S.doGet().getContent(), "ok");
});

test("peer text lands as text, never as a formula; zero-row tool reads back as -", () => {
  const { S, ss } = fresh();
  const b = validBody();
  b.member.nickname = "=1+1";
  b.days = [{ date: "2026-11-16", team: "t_ab12cd34ef56", teamLabel: "-팀", tools: [] }];
  assert.equal(report(S, b).ok, true);
  const read = (tab, r, c) => ss.getSheetByName(tab).getRange(r, c).getValues()[0][0];
  // the leading = and - arrive already neutralised at parse time (full-width twins), so no cell can evaluate
  assert.equal(read("원본", 2, 2), "\uFF1D1+1");
  assert.equal(read("원본", 2, 4), "-");
  assert.equal(read("사람", 2, 2), "\uFF1D1+1");
  assert.equal(read("부서", 2, 3), "\uFF0D팀");
  // a second report rewrites the existing rows and must keep them text
  assert.equal(report(S, b).ok, true);
  assert.equal(read("원본", 2, 2), "\uFF1D1+1");
  assert.equal(read("사람", 2, 2), "\uFF1D1+1");
  // asText stays the backstop for script-written text: a leading marker stores as text
  assert.equal(S.asText("=1+1"), "'=1+1");
});

const OTHER = "11111111-2222-4333-8444-555555555555";

function limitRows(ss) { return dataRows(ss, "한도"); }

test("a second memberId reporting the same account and window gets its own row; the victim's row is untouched", () => {
  const { S, ss } = fresh();
  report(S, validBody());
  const before = JSON.stringify(limitRows(ss)[0]);
  const b = validBody();
  b.member.id = OTHER;
  b.member.secret = "attacker-secret-attacker-secret-0000";
  b.member.nickname = "누군가";
  b.days = [];
  b.limits[0].usedPercent = 1000;
  b.limits[0].readAt = new Date(NOW + 9 * 60000).toISOString();
  b.limits[0].team = "t_attacker_team";
  assert.equal(report(S, b).ok, true);
  const rows = limitRows(ss);
  assert.equal(rows.length, 2);
  assert.equal(JSON.stringify(rows[0]), before);
  assert.equal(rows[0][7] < 1000, true);
  assert.equal(rows[1][3], OTHER);
  assert.equal(rows[1][7], 1000);
});

test("resets within 24h of each other are one weekly window, 7 days later is a new row", () => {
  const { S, ss } = fresh();
  report(S, limitBody(10, "2026-11-19T08:30:01Z", "2026-11-16T01:00:00Z"));
  report(S, limitBody(20, "2026-11-19T08:29:59Z", "2026-11-16T02:00:00Z"));
  let rows = limitRows(ss);
  assert.equal(rows.length, 1);
  assert.equal(rows[0][2], "2026-11-19T08:00:00.000Z");   // the incoming, hour-snapped value
  assert.equal(rows[0][8], 20);
  // a reset 7 days later only passes the contract's 8-day bound once the clock has moved on
  report(S, limitBody(5, "2026-11-26T08:30:00Z", "2026-11-20T02:00:00Z"), NOW + 4 * 86400000);
  rows = limitRows(ss);
  assert.equal(rows.length, 2);
});

test("an owner-named department keeps its name across reports", () => {
  const { S, ss } = fresh();
  report(S, validBody());
  ss.getSheetByName("부서")._rows[1][1] = "개발팀";
  report(S, validBody(), NOW + 1000);
  report(S, validBody(), NOW + 2000);
  assert.deepEqual(dataRows(ss, "부서").map((r) => [r[0], r[1]]), [["t_ab12cd34ef56", "개발팀"]]);
});

function editAfterRead(sheet, row, col, val) {
  const orig = sheet.getRange.bind(sheet);
  let edited = false;
  sheet.getRange = (r, c, nr, nc) => {
    const g = orig(r, c, nr, nc);
    const gv = g.getValues.bind(g);
    g.getValues = () => {
      const v = gv();
      if (!edited && r === 2) { edited = true; sheet._rows[row][col] = val; }
      return v;
    };
    return g;
  };
}

test("an owner edit landing between the read and the write survives (부서, 사람)", () => {
  for (const [tab, col, val] of [["부서", 1, "개발팀"], ["사람", 3, "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"]]) {
    const { S, ss } = fresh();
    report(S, validBody());
    editAfterRead(ss.getSheetByName(tab), 1, col, val);
    report(S, validBody(), NOW + 1000);
    assert.equal(ss.getSheetByName(tab)._rows[1][col], val, tab);
  }
  // the person's own columns still update
  const { S, ss } = fresh();
  report(S, validBody());
  const b = validBody();
  b.member.nickname = "새이름";
  b.member.appVersion = "2.6.0";
  report(S, b, NOW + 1000);
  const p = dataRows(ss, "사람")[0];
  assert.equal(p[1], "새이름");
  assert.equal(p[4], "2.6.0");
  assert.equal(p[2], new Date(NOW + 1000).toISOString());
});

test("an unchanged row is not rewritten", () => {
  const { S, ss } = fresh();
  report(S, validBody());
  const sheet = ss.getSheetByName("부서");
  const orig = sheet.getRange.bind(sheet);
  let writes = 0;
  sheet.getRange = (...a) => {
    const g = orig(...a);
    const sv = g.setValues.bind(g);
    g.setValues = (v) => { writes++; return sv(v); };
    return g;
  };
  report(S, validBody(), NOW + 1000);
  assert.equal(writes, 0);
});

test("an over-long body is rejected before the lock or any tab", () => {
  const { S, ss } = fresh();
  const r = plain(S.handleReport(ss, "a".repeat(262145), NOW, TZ));
  assert.deepEqual(r, { ok: false, error: "too_large" });
  assert.equal(S.fakes.lockStats.acquired, 0);
});

test("one 21-day x 3-tool report reads at most the key columns of 5000 raw rows", () => {
  const { S, ss } = fresh();
  S.ensureSheets(ss);
  const raw = ss.getSheetByName("원본");
  for (let i = 0; i < 5000; i++) {
    raw._rows.push([OTHER, "누군가", "2026-01-01", "claude_code", "t_ab12cd34ef56", 1, 1, 1, 1, 4, "2.5.0", "mac", "x"]);
  }
  raw._maxRows = 5001;
  const b = validBody();
  b.limits = [];
  b.days = [];
  for (let d = 0; d < 21; d++) {
    const date = new Date(Date.UTC(2026, 10, 16 - d)).toISOString().slice(0, 10);
    b.days.push({ date, team: "t_ab12cd34ef56", tools: ["claude_code", "codex", "gemini"].map((tool) => (
      { tool, input: 1, output: 1, cacheWrite: 1, cacheRead: 1 })) });
  }
  raw._cellsRead = 0;
  assert.equal(report(S, b).accepted.days, 63);
  assert.equal(raw._cellsRead <= 5000 * 4 + 100, true, `read ${raw._cellsRead} cells`);
});

// ---- intake limits, resend writes, formula text, tool allowlist ----

function opsOn(ss, tab) { return ss.getSheetByName(tab)._ops.length; }
function manyDays(S, n, tools) {
  const b = validBody();
  b.limits = [];
  b.days = [];
  for (let d = 0; d < n; d++) {
    b.days.push({ date: S.localDateString(NOW - d * 86400000, TZ), team: "t_ab12cd34ef56",
      tools: S.ALLOWED_TOOLS.slice(0, tools).map((tool) => ({ tool, input: 1, output: 1, cacheWrite: 1, cacheRead: 1 })) });
  }
  return b;
}
function memberBody(S, i) {
  const b = validBody();
  b.member.id = "00000001-0000-4000-8000-" + String(i).padStart(12, "0");
  b.member.secret = "s".repeat(31) + String(i % 10);
  b.limits = [];
  return b;
}

test("a resend of the same keys with the same numbers writes no raw row", () => {
  const { S, ss } = fresh();
  assert.equal(report(S, validBody()).ok, true);
  const ops = opsOn(ss, "원본");
  const before = JSON.stringify(dataRows(ss, "원본"));
  assert.equal(report(S, validBody(), NOW + 3600000).ok, true);
  assert.equal(opsOn(ss, "원본"), ops);
  assert.equal(JSON.stringify(dataRows(ss, "원본")), before);
});

test("a resend that changes one number rewrites only that row", () => {
  const { S, ss } = fresh();
  report(S, validBody());
  const ops = opsOn(ss, "원본");
  const b = validBody();
  b.days[0].tools[0].input += 5;
  report(S, b, NOW + 3600000);
  assert.equal(opsOn(ss, "원본"), ops + 1);
  assert.equal(dataRows(ss, "원본")[0][5], b.days[0].tools[0].input);
});

test("a flood of resent keys keeps the lock short: no per-row writes", () => {
  const { S, ss } = fresh();
  const b = manyDays(S, 62, 16);
  assert.equal(report(S, b).ok, true);
  const ops = opsOn(ss, "원본");
  assert.equal(report(S, b, NOW + 1000).ok, true);
  assert.equal(opsOn(ss, "원본"), ops);
});

test("honest maximum passes: 21 days of all 16 tools, new member, every cap untouched", () => {
  const { S, ss } = fresh();
  const b = manyDays(S, 21, 16);
  b.limits = validBody().limits;
  assert.deepEqual(report(S, b), { ok: true, accepted: { days: 336, limits: 1 }, dropped: 0 });
});

test("new members past the hourly cap get rate_limited and nothing is written for them", () => {
  const { S, ss } = fresh();
  const cap = S.MAX_NEW_MEMBERS_PER_HOUR;
  for (let i = 0; i < cap; i++) assert.equal(report(S, memberBody(S, i)).ok, true, "member " + i);
  const raw = dataRows(ss, "원본").length;
  assert.deepEqual(report(S, memberBody(S, cap)), { ok: false, error: "rate_limited" });
  assert.equal(dataRows(ss, "원본").length, raw);
  assert.equal(dataRows(ss, "기기").length, cap);
  // a known member still reports in the same hour
  assert.equal(report(S, memberBody(S, 0)).ok, true);
  // the next hour admits new members again, and the refused one now succeeds
  assert.equal(report(S, memberBody(S, cap), NOW + 3600000).ok, true);
});

test("members past the total cap get sheet_full", () => {
  const { S, ss } = fresh();
  S.ensureSheets(ss);
  const dev = ss.getSheetByName("기기");
  for (let i = 0; i < S.MAX_MEMBERS_TOTAL; i++) dev._rows.push([`m${i}`, "h", "", ""]);
  dev._maxRows = S.MAX_MEMBERS_TOTAL + 10;
  assert.deepEqual(report(S, memberBody(S, 1)), { ok: false, error: "sheet_full" });
  // a registered member is not a new member
  dev._rows[1] = [memberBody(S, 1).member.id, S.sha256Hex(memberBody(S, 1).member.secret), "", ""];
  assert.equal(report(S, memberBody(S, 1)).ok, true);
});

test("new raw rows past the hourly cap get rate_limited before anything is written", () => {
  const { S, ss } = fresh();
  // fill this hour's budget through the stored counter, as a flood of earlier requests would
  const hour = Math.floor(NOW / 3600000);
  S.fakes.props.doc.intake_hour = JSON.stringify({ hour, members: 0, raw: S.MAX_NEW_RAW_ROWS_PER_HOUR - 2, limits: 0 });
  const r = report(S, validBody());   // 3 new raw rows, 2 left
  assert.deepEqual(r, { ok: false, error: "rate_limited" });
  assert.equal(dataRows(ss, "원본").length, 0);
  // exactly what is left still fits
  const b = validBody();
  b.days = [b.days[0]];
  b.days[0].tools = b.days[0].tools.slice(0, 2);
  assert.equal(report(S, b).ok, true);
  // and a new hour starts from zero
  assert.equal(report(S, validBody(), NOW + 3600000).ok, true);
});

test("new raw rows past the total cap get sheet_full; resent keys still pass", () => {
  const { S, ss } = fresh();
  assert.equal(report(S, validBody()).ok, true);
  const raw = ss.getSheetByName("원본");
  const have = dataRows(ss, "원본").length;
  const filler = S.MAX_RAW_ROWS_TOTAL - have;   // leave the tab exactly full
  raw._maxRows = S.MAX_RAW_ROWS_TOTAL + 10;
  for (let i = 0; i < filler; i++) raw._rows.push(["x", "", "", "", "", 0, 0, 0, 0, 0, "", "", ""]);
  const more = validBody();
  more.days = [{ date: "2026-11-10", team: "t_ab12cd34ef56", tools: [{ tool: "grok", input: 1, output: 1, cacheWrite: 1, cacheRead: 1 }] }];
  assert.deepEqual(report(S, more, NOW + 1000), { ok: false, error: "sheet_full" });
  assert.equal(report(S, validBody(), NOW + 2000).ok, true);
});

test("new limit rows past the hourly cap get rate_limited", () => {
  const { S, ss } = fresh();
  const hour = Math.floor(NOW / 3600000);
  S.fakes.props.doc.intake_hour = JSON.stringify({ hour, members: 0, raw: 0, limits: S.MAX_NEW_LIMIT_ROWS_PER_HOUR });
  assert.deepEqual(report(S, validBody()), { ok: false, error: "rate_limited" });
  assert.equal(dataRows(ss, "한도").length, 0);
});

test("a leading = + - @ in nickname, team label and plan is neutralised but stays readable", () => {
  const { S, ss } = fresh();
  const b = validBody();
  b.member.nickname = '=HYPERLINK("http://x","a")';
  b.days = [{ date: "2026-11-16", team: "t_ab12cd34ef56", teamLabel: "+팀", tools: [] }];
  b.limits[0].plan = "@Max";
  assert.equal(report(S, b).ok, true);
  const all = JSON.stringify(ss.getSheets().map((s) => s._rows));
  for (const bad of ['"=HYP', '"+팀', '"@Max', "\'=HYP"]) assert.equal(all.includes(bad), false, bad);
  assert.equal(dataRows(ss, "사람")[0][1], '\uFF1DHYPERLINK("http://x","a")');
  assert.equal(dataRows(ss, "부서")[0][2], "\uFF0B팀");
  assert.equal(dataRows(ss, "한도")[0][5], "\uFF20Max");
  // a nickname that merely contains the characters later is untouched
  b.member.nickname = "a=b-c@d";
  report(S, b, NOW + 1000);
  assert.equal(dataRows(ss, "사람")[0][1], "a=b-c@d");
});

test("the tool allowlist covers every provider ID the app declares", () => {
  const { S } = fresh();
  const root = path.join(__dirname, "..", "..", "..", "Sources", "PokeTokenBar", "Core");
  const ids = [];
  for (const f of ["LocalUsageProvider.swift", "LocalAdditionalUsageProvider.swift"]) {
    const text = fs.readFileSync(path.join(root, f), "utf8");
    for (const m of text.matchAll(/^\s*let id = "([a-z0-9_]+)"/gm)) ids.push(m[1]);
  }
  assert.equal(ids.length >= 16, true, "found " + ids.length);
  for (const id of ids) assert.equal(S.ALLOWED_TOOLS.includes(id), true, id);
  assert.deepEqual(plain(S.ALLOWED_LIMIT_TOOLS), ["claude", "codex"]);
});
