"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { loadScript, DEFAULT_NOW_MS } = require("./harness.js");

const S = loadScript();
const NOW = DEFAULT_NOW_MS;
const TZ = "Asia/Seoul";
const fixtureDir = path.join(__dirname, "..", "fixtures");

function fixture(name) {
  return JSON.parse(fs.readFileSync(path.join(fixtureDir, name), "utf8"));
}
function validBody() {
  return JSON.parse(JSON.stringify(fixture("valid-basic.json").body));
}
// Values built inside the vm context have foreign prototypes; compare through JSON.
function plain(v) {
  return JSON.parse(JSON.stringify(v));
}
function parse(body) {
  return S.parsePayload(JSON.stringify(body), NOW, TZ);
}

for (const file of fs.readdirSync(fixtureDir).filter((f) => f.endsWith(".json")).sort()) {
  test(`fixture ${file}`, () => {
    const { body, expect } = fixture(file);
    const r = parse(body);
    assert.equal(r.ok, expect.ok);
    if (!expect.ok) {
      assert.equal(r.error, expect.error);
      return;
    }
    assert.equal(r.days.length, expect.days);
    assert.equal(r.limits.length, expect.limits);
    assert.equal(r.dropped, expect.dropped);
  });
}

test("valid-basic: an empty-tools day becomes one zero '-' row", () => {
  const r = parse(validBody());
  assert.deepEqual(plain(r.days[1].tools), [{ tool: "-", input: 0, output: 0, cacheWrite: 0, cacheRead: 0 }]);
  assert.equal(r.member.nickname, "지아");
});

test("rows-mixed keeps only the good tool", () => {
  const r = parse(fixture("rows-mixed.json").body);
  assert.equal(r.days[0].tools.length, 1);
  assert.equal(r.days[0].tools[0].tool, "claude_code");
});

test("body of 262145 bytes is too_large; 262144 is not", () => {
  assert.equal(S.parsePayload("a".repeat(262145), NOW, TZ).error, "too_large");
  assert.notEqual(S.parsePayload("a".repeat(262144), NOW, TZ).error, "too_large");
});

test("utf8Length counts bytes by code point", () => {
  assert.equal(S.utf8Length("a"), 1);
  assert.equal(S.utf8Length("지"), 3);
  assert.equal(S.utf8Length("é"), 2);
  assert.equal(S.utf8Length("😀"), 4);
  assert.equal(S.utf8Length("\ud800"), 3);
});

test("multi-byte body over the byte limit is too_large", () => {
  assert.equal(S.parsePayload("지".repeat(87382), NOW, TZ).error, "too_large");
});

test("bad json", () => {
  assert.equal(S.parsePayload("{", NOW, TZ).error, "bad_json");
  assert.equal(S.parsePayload("[]", NOW, TZ).error, "bad_json");
  assert.equal(S.parsePayload("null", NOW, TZ).error, "bad_json");
});

test("63 days is too_many_rows; 62 is fine", () => {
  const b = validBody();
  const mk = (n) => Array.from({ length: n }, (_, i) => ({
    date: S.localDateString(NOW - i * 86400000, TZ), team: "t_ab12cd34ef56", tools: [],
  }));
  b.days = mk(63);
  assert.equal(parse(b).error, "too_many_rows");
  b.days = mk(62);
  assert.equal(parse(b).ok, true);
});

test("17 limits and 33 tools are too_many_rows", () => {
  const b = validBody();
  b.limits = Array.from({ length: 17 }, () => b.limits[0]);
  assert.equal(parse(b).error, "too_many_rows");
  const c = validBody();
  c.days[0].tools = Array.from({ length: 33 }, (_, i) => ({ tool: `t${i}`, input: 1, output: 1, cacheWrite: 1, cacheRead: 1 }));
  assert.equal(parse(c).error, "too_many_rows");
});

test("omitted limits means none", () => {
  const b = validBody();
  delete b.limits;
  const r = parse(b);
  assert.equal(r.ok, true);
  assert.deepEqual(plain(r.limits), []);
});

test("member validation", () => {
  for (const [k, v] of [["id", "nope"], ["secret", "short"], ["nickname", "  "], ["nickname", "a\nb"],
    ["appVersion", "bad version"], ["platform", "linux"]]) {
    const b = validBody();
    b.member[k] = v;
    assert.equal(parse(b).error, "bad_member", `${k}=${v}`);
  }
});

test("nickname rule: app-valid grapheme nicknames pass, 321 bytes does not", () => {
  const cases = [
    ["열한글자열한글자열한글" + "\u{1F44D}\u{1F3FB}", true],           // 11 Hangul + thumbs-up with skin tone
    ["\u{1F1F0}\u{1F1F7}", true],                                         // flag emoji
    ["\u{1F468}\u200D\u{1F469}\u200D\u{1F467}\u200D\u{1F466}", true], // ZWJ family
    ["a".repeat(320), true],
    ["a".repeat(321), false],
    ["가".repeat(107), false],                                              // 321 bytes
  ];
  for (const [nick, ok] of cases) {
    const b = validBody();
    b.member.nickname = nick;
    assert.equal(parse(b).ok, ok, JSON.stringify(nick));
  }
});

test("team ids need the t_ prefix, for days and limits", () => {
  for (const team of ["123456", "1e5abc", "ab12cd34ef56", "t_a", "t_" + "a".repeat(63)]) {
    const b = validBody();
    b.days = [{ date: "2026-11-16", team, tools: [] }];
    b.limits[0].team = team;
    const r = parse(b);
    assert.equal(r.days.length, 0, team);
    assert.equal(r.limits.length, 0, team);
  }
  const b = validBody();
  b.days = [{ date: "2026-11-16", team: "t_ab", tools: [] }];
  b.limits[0].team = "t_" + "a".repeat(62);
  const r = parse(b);
  assert.equal(r.days.length, 1);
  assert.equal(r.limits.length, 1);
});

test("a __proto__ tool id twice in one day gives one row with the last values", () => {
  const b = validBody();
  b.days = [{ date: "2026-11-16", team: "t_ab12cd34ef56", tools: [
    { tool: "__proto__", input: 1, output: 1, cacheWrite: 1, cacheRead: 1 },
    { tool: "__proto__", input: 9, output: 9, cacheWrite: 9, cacheRead: 9 },
  ] }];
  const r = parse(b);
  assert.equal(r.days[0].tools.length, 1);
  assert.deepEqual(plain(r.days[0].tools[0]), { tool: "__proto__", input: 9, output: 9, cacheWrite: 9, cacheRead: 9 });
  assert.equal(({}).input, undefined);
});

test("account ids need the e_ or m_ prefix", () => {
  for (const [account, ok] of [["123456", false], ["1e5abc", false], ["x_abcd", false], ["sample_c1", false],
    ["e_3f9a1c2b4d5e6f70", true], ["m_8F1C2A4E-3B5D-4C6E-9A7B-1D2E3F4A5B6C_acc1", true], ["e_a", false]]) {
    const b = validBody();
    b.limits[0].account = account;
    assert.equal(parse(b).limits.length, ok ? 1 : 0, account);
  }
});

test("a repeated date/tool keeps the last occurrence", () => {
  const b = validBody();
  b.days = [{ date: "2026-11-16", team: "t_ab12cd34ef56", tools: [
    { tool: "claude_code", input: 1, output: 1, cacheWrite: 1, cacheRead: 1 },
    { tool: "claude_code", input: 9, output: 8, cacheWrite: 7, cacheRead: 6 },
  ] }];
  const r = parse(b);
  assert.equal(r.days[0].tools.length, 1);
  assert.deepEqual(plain(r.days[0].tools[0]), { tool: "claude_code", input: 9, output: 8, cacheWrite: 7, cacheRead: 6 });
});

test("a non-empty tools list that loses every entry drops the day", () => {
  const b = validBody();
  b.days = [{ date: "2026-11-16", team: "t_ab12cd34ef56", tools: [
    { tool: "claude_code", input: -1, output: 1, cacheWrite: 1, cacheRead: 1 },
  ] }];
  const r = parse(b);
  assert.equal(r.days.length, 0);
  assert.equal(r.dropped, 2);
});

test("date window and calendar validity", () => {
  const cases = [["2026-11-17", true], ["2026-11-18", false], ["2025-10-12", true], ["2025-10-11", false],
    ["2026-02-30", false], ["2026-13-01", false], ["2026-1-1", false]];
  for (const [date, ok] of cases) {
    const b = validBody();
    b.days = [{ date, team: "t_ab12cd34ef56", tools: [] }];
    assert.equal(parse(b).days.length, ok ? 1 : 0, date);
  }
});

test("invalid team drops the day", () => {
  const b = validBody();
  b.days = [{ date: "2026-11-16", team: "x", tools: [] }];
  assert.equal(parse(b).days.length, 0);
});

test("an invalid teamLabel becomes '' and the day is kept", () => {
  const b = validBody();
  b.days = [{ date: "2026-11-16", team: "t_ab12cd34ef56", teamLabel: "a".repeat(321), tools: [] }];
  const r = parse(b);
  assert.equal(r.days.length, 1);
  assert.equal(r.days[0].teamLabel, "");
  assert.equal(r.dropped, 0);
});

test("resetsAt jitter normalizes to the nearest hour", () => {
  for (const t of ["2026-11-19T08:59:40Z", "2026-11-19T09:00:20Z"]) {
    const b = validBody();
    b.limits[0].resetsAt = t;
    assert.equal(parse(b).limits[0].resetsAt, "2026-11-19T09:00:00.000Z", t);
  }
});

test("domain is lowercased", () => {
  const b = validBody();
  b.limits[0].domain = "LikeLion.NET";
  assert.equal(parse(b).limits[0].domain, "likelion.net");
});

test("limit time windows", () => {
  const cases = [
    ["resetsAt", "2026-11-24T03:00:00Z", true], ["resetsAt", "2026-11-24T03:00:01Z", false],
    ["resetsAt", "2026-11-08T03:00:00Z", true], ["resetsAt", "2026-11-08T02:59:00Z", false],
    ["readAt", "2026-11-16T03:10:00Z", true], ["readAt", "2026-11-16T03:10:01Z", false],
    ["readAt", "2026-11-08T03:00:00Z", true], ["readAt", "2026-11-08T02:59:59Z", false],
    ["readAt", "garbage", false],
  ];
  for (const [field, value, ok] of cases) {
    const b = validBody();
    b.limits[0][field] = value;
    assert.equal(parse(b).limits.length, ok ? 1 : 0, `${field}=${value}`);
  }
});

test("limit field rules", () => {
  const bad = [["account", "ab"], ["domain", "bad domain"], ["plan", ""], ["plan", "x".repeat(41)],
    ["usedPercent", -1], ["usedPercent", 1001], ["usedPercent", null], ["tool", "Bad Tool"], ["team", "x"]];
  for (const [k, v] of bad) {
    const b = validBody();
    b.limits[0][k] = v;
    assert.equal(parse(b).limits.length, 0, `${k}=${v}`);
  }
  const b = validBody();
  b.limits[0].domain = "";
  assert.equal(parse(b).limits[0].domain, "");
});

test("count bounds", () => {
  const cases = [[1e13, true], [1e13 + 1, false], [-1, false], [1.5, false], ["5", false], [NaN, false]];
  for (const [n, ok] of cases) {
    const b = validBody();
    b.days = [{ date: "2026-11-16", team: "t_ab12cd34ef56", tools: [{ tool: "claude_code", input: n, output: 0, cacheWrite: 0, cacheRead: 0 }] }];
    assert.equal(parse(b).days.length, ok ? 1 : 0, String(n));
  }
});

test("localDateString uses the time zone", () => {
  assert.equal(S.localDateString(Date.parse("2026-11-15T15:30:00Z"), "Asia/Seoul"), "2026-11-16");
  assert.equal(S.localDateString(Date.parse("2026-11-15T15:30:00Z"), "UTC"), "2026-11-15");
});

test("config constants", () => {
  assert.equal(S.SHARED_TOKEN, "996c41db62671eaf62a86cf3e18202ee");
  assert.equal(S.MAX_BODY_BYTES, 262144);
  assert.equal(S.TAB_RAW, "원본");
  assert.equal(S.COLS_RAW.length, 13);
  assert.equal(S.DEFAULT_SETTINGS.length, 10);
  assert.equal(S.DASHBOARD_TABS.length, 3);
});
