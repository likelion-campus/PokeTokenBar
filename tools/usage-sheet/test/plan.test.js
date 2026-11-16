"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { loadScript } = require("./harness.js");

const NOW = Date.parse("2026-11-16T03:00:00Z");
const DAY = 86400000;
const S = loadScript({ nowMs: NOW });
function plain(v) { return JSON.parse(JSON.stringify(v)); }
function map(o) { const m = Object.create(null); Object.keys(o).forEach((k) => { m[k] = o[k]; }); return m; }

const DEFAULTS = {
  forecast_short_pct: 100, forecast_fit_pct: 70, full_week_pct: 100, suggest_weeks: 4, suggest_up_full_weeks: 2,
  suggest_down_max_pct: 40, min_pace: 0.1, stale_hours: 24,
  plan_order_claude: ["Pro", "Max", "Ultra"], plan_order_codex: ["plus", "pro"],
};
function mkData(over) {
  return Object.assign({
    usage: [], limits: [],
    people: map({ m1: { nickname: "해달", mergeInto: "" }, m2: { nickname: "지아", mergeInto: "" },
      m3: { nickname: "모카", mergeInto: "" }, m4: { nickname: "서연", mergeInto: "" } }),
    depts: map({ t1: { name: "개발", suggested: "" } }), teamLabels: [], settings: Object.assign({}, DEFAULTS),
  }, over);
}
// A current window that resets in `daysLeft` days, read `ageH` hours ago.
function current(account, member, plan, used, daysLeft, o) {
  const x = o || {};
  const resetsAt = NOW + daysLeft * DAY;
  return { account, tool: x.tool || "claude", resetsAt, memberId: member, team: x.team || "t1", plan, domain: x.domain || "",
    maxUsed: used, lastUsed: used, lastReadAt: NOW - (x.ageH || 0) * 3600000 };
}
function finished(account, member, plan, maxes, o) {
  const x = o || {};
  return maxes.map((m, i) => ({ account, tool: x.tool || "claude", resetsAt: NOW - (i * 7 + 1) * DAY, memberId: member,
    team: x.team || "t1", plan, domain: "", maxUsed: m, lastUsed: m, lastReadAt: NOW - (i * 7 + 1.5) * DAY }));
}
function plan(data) { return plain(S.computePlan(data, NOW, "Asia/Seoul")); }
function byNick(model, nick) { return model.rows.filter((r) => r.nickname === nick); }

function mockLimits() {
  return [].concat(
    current("a1", "m1", "Max", 82, 2.5), finished("a1", "m1", "Max", [100, 100, 100, 70]),
    current("a2", "m2", "Max", 20, 2.9), finished("a2", "m2", "Max", [10, 20, 30, 25]),
    current("a3", "m3", "Pro", 100, 3), finished("a3", "m3", "Pro", [100, 100, 100, 100]),
    current("a4", "m4", "Pro", 3, 3), finished("a4", "m4", "Pro", [5, 3, 8, 1]));
}

test("the mock's four rows", () => {
  const m = plan(mkData({ limits: mockLimits() }));
  const a = byNick(m, "해달")[0];
  assert.equal(a.forecast, "모자람");
  assert.ok(Math.abs(a.pacePct - 64.3) < 0.1);
  assert.ok(Math.abs(a.projectedPct - 127.6) < 0.5);
  assert.equal(a.suggestion, "올리기 검토 → Ultra");
  assert.equal(a.fullWeeks, 3);
  assert.equal(a.finishedWeeks, 4);
  const b = byNick(m, "지아")[0];
  assert.equal(b.forecast, "남음");
  assert.ok(Math.abs(b.projectedPct - 34.1) < 0.5);
  assert.equal(b.suggestion, "내리기 검토 → Pro");
  const c = byNick(m, "모카")[0];
  assert.equal(c.forecast, "이미 다 씀");
  assert.equal(c.suggestion, "올리기 검토 → Max");
  const d = byNick(m, "서연")[0];
  assert.equal(d.suggestion, "필요한지 검토");
  assert.equal(d.team, "개발");
  assert.deepEqual(m.rows.map((r) => r.nickname), ["모카", "해달", "지아", "서연"]);
  assert.deepEqual(plain(m.tiles), { short: 2, fit: 0, spare: 2, noInfo: 0 });
});

test("suggestion edge cases", () => {
  const top = plan(mkData({ limits: [].concat(current("u", "m1", "ultra", 50, 3), finished("u", "m1", "ultra", [100, 100, 10, 10])) }));
  assert.equal(top.rows[0].suggestion, "최상위 플랜");
  const team = plan(mkData({ limits: [].concat(current("u", "m1", "Team", 50, 3), finished("u", "m1", "Team", [100, 100, 10, 10])) }));
  assert.equal(team.rows[0].suggestion, "올리기 검토");
  const low = plan(mkData({ limits: [].concat(current("u", "m1", "Team", 5, 3), finished("u", "m1", "Team", [1, 1, 1, 1])) }));
  assert.equal(low.rows[0].suggestion, "내리기 검토");
  const few = plan(mkData({ limits: [].concat(current("u", "m1", "Max", 50, 3), finished("u", "m1", "Max", [100, 100])) }));
  assert.equal(few.rows[0].suggestion, "기록 부족");
  const keep = plan(mkData({ limits: [].concat(current("u", "m1", "Max", 50, 3), finished("u", "m1", "Max", [100, 60, 50, 10])) }));
  assert.equal(keep.rows[0].suggestion, "유지");
  const noOrder = plan(mkData({ limits: [].concat(current("u", "m1", "Max", 50, 3, { tool: "gemini" }), finished("u", "m1", "Max", [100, 100, 1, 1], { tool: "gemini" })) }));
  assert.equal(noOrder.rows[0].suggestion, "올리기 검토");
});

test("projection is null when too early or too stale", () => {
  const early = plan(mkData({ limits: [current("u", "m1", "Max", 5, 6.65)] }));
  assert.equal(early.rows[0].projectedPct, null);
  assert.equal(early.rows[0].forecast, "—");
  const stale = plan(mkData({ limits: [current("u", "m1", "Max", 50, 3, { ageH: 30 })] }));
  assert.equal(stale.rows[0].projectedPct, null);
  assert.equal(stale.rows[0].forecast, "—");
  const none = plan(mkData({ limits: finished("u", "m1", "Max", [10]) }));
  assert.equal(none.rows[0].usedPct, null);
  assert.equal(none.rows[0].forecast, "—");
  assert.deepEqual(plain(none.tiles), { short: 0, fit: 0, spare: 0, noInfo: 0 });
});

test("settings: threshold moves a category, bad value falls back (Review Focus 3)", () => {
  // used 54 at pace 0.643 -> projected 84
  const limits = [current("u", "m1", "Max", 54, 2.5)];
  assert.equal(plan(mkData({ limits })).rows[0].forecast, "알맞음");
  const moved = mkData({ limits, settings: Object.assign({}, DEFAULTS, { forecast_fit_pct: 90 }) });
  assert.equal(plan(moved).rows[0].forecast, "남음");
  // through the real sheet-settings path
  const bad = S.parseSettings([["forecast_fit_pct", "abc"], ["stale_hours", ""], ["suggest_weeks", "-3"]]);
  const m = plan(mkData({ limits, settings: bad }));
  assert.equal(m.rows[0].forecast, "알맞음");
  assert.ok(m.rows.every((r) => !String(r.forecast).includes("NaN")));
});

test("one person with two accounts: once in tiles, twice in rows", () => {
  const limits = [].concat(current("a", "m1", "Max", 82, 2.5), current("b", "m1", "Pro", 10, 2.5, { domain: "x.com" }));
  const m = plan(mkData({ limits }));
  assert.equal(m.rows.length, 2);
  assert.deepEqual(plain(m.tiles), { short: 1, fit: 0, spare: 0, noInfo: 0 });
  assert.equal(m.rows[0].forecast, "모자람");
});

test("merged members count as one person", () => {
  const people = map({ m1: { nickname: "해달", mergeInto: "" }, m5: { nickname: "해달2", mergeInto: "m1" } });
  const limits = [].concat(current("a", "m1", "Max", 82, 2.5), current("b", "m5", "Max", 10, 2.5));
  const m = plan(mkData({ limits, people }));
  assert.equal(m.rows.length, 2);
  assert.ok(m.rows.every((r) => r.nickname === "해달"));
  assert.deepEqual(plain(m.tiles), { short: 1, fit: 0, spare: 0, noInfo: 0 });
});

test("noInfo: usage in the last 7 days but no recent limit row", () => {
  const usage = [
    { memberId: "m1", date: "2026-11-16", tool: "claude_code", team: "t1", total: 5 },
    { memberId: "m2", date: "2026-11-10", tool: "claude_code", team: "t1", total: 5 },   // today-6: in
    { memberId: "m3", date: "2026-11-09", tool: "claude_code", team: "t1", total: 5 },   // today-7: out
    { memberId: "m4", date: "2026-11-16", tool: "claude_code", team: "tX", total: 5 },   // unassigned: out
  ];
  const limits = [{ account: "o", tool: "claude", resetsAt: NOW + DAY, memberId: "m2", team: "t1", plan: "Max", domain: "",
    maxUsed: 1, lastUsed: 1, lastReadAt: NOW - 2 * DAY }];
  const m = plan(mkData({ usage, limits }));
  assert.equal(m.tiles.noInfo, 1);
  const stale = plan(mkData({ usage, limits: [Object.assign({}, limits[0], { lastReadAt: NOW - 8 * DAY })] }));
  assert.equal(stale.tiles.noInfo, 2);
});

test("unassigned-department accounts are excluded and counted", () => {
  const limits = [].concat(current("a", "m1", "Max", 50, 3), current("b", "m2", "Max", 50, 3, { team: "tX" }));
  const m = plan(mkData({ limits }));
  assert.equal(m.rows.length, 1);
  assert.equal(m.excludedAccounts, 1);
});

test("sorting: forecast rank, projected desc with null last, nickname", () => {
  const people = map({ m1: { nickname: "나", mergeInto: "" }, m2: { nickname: "가", mergeInto: "" }, m3: { nickname: "다", mergeInto: "" },
    m4: { nickname: "라", mergeInto: "" } });
  const limits = [current("a", "m1", "Max", 80, 2.5), current("b", "m2", "Max", 90, 2.5),
    current("c", "m3", "Max", 5, 6.65), current("d", "m4", "Max", 80, 2.5)];
  const m = plan(mkData({ limits, people }));
  assert.deepEqual(m.rows.map((r) => r.nickname), ["가", "나", "라", "다"]);
});

test("renderPlan writes header, rows and the SPARKLINE formula", () => {
  const ss = S.fakes.ss;
  const sheet = ss.insertSheet("플랜");
  const model = S.computePlan(mkData({ limits: mockLimits() }), NOW, "Asia/Seoul");
  S.renderPlan(sheet, model, NOW, "Asia/Seoul");
  const v = (r, c, nr, nc) => sheet.getRange(r, c, nr || 1, nc || 1).getValues();
  assert.equal(v(1, 1)[0][0], "플랜과 주간 한도 — 지금 진행 중인 주");
  assert.equal(v(2, 1)[0][0], "마지막 갱신: 2026-11-16 12:00");
  assert.deepEqual(v(4, 1, 1, 4)[0], ["이번 주 모자랄 사람", "알맞게 쓸 사람", "남길 사람", "플랜 정보 없음"]);
  assert.deepEqual(v(5, 1, 1, 4)[0], [2, 0, 2, 0]);
  assert.deepEqual(v(7, 1, 1, 13)[0], ["닉네임", "부서", "도구", "플랜", "이메일 도메인", "이번 주 사용", "막대", "균등하게 썼다면",
    "리셋까지(일)", "이 속도면 리셋 때", "예상", "지난 4주 중 다 쓴 주", "제안"]);
  const first = v(8, 1, 1, 13)[0];
  assert.equal(first[0], "모카");
  assert.equal(first[2], "Claude");
  assert.equal(first[5], 100);
  assert.equal(first[6], "#FORMULA");
  assert.equal(first[11], "4 / 4");
  assert.equal(sheet.getRange(8, 7).getFormula(), '=SPARKLINE(F8,{"charttype","bar";"max",100})');
  assert.equal(sheet.getRange(11, 7).getFormula(), '=SPARKLINE(F11,{"charttype","bar";"max",100})');
  assert.equal(v(12, 1)[0][0], "");
  const all = sheet.getRange(1, 1, 20, 1).getValues().map((r) => r[0]);
  assert.ok(all.includes("미지정 부서라 빠진 계정: 0개"));
});

test("renderPlan guards formula-like text and clears first", () => {
  const sheet = S.fakes.ss.insertSheet("플랜2");
  sheet.getRange(30, 1).setValue("old");
  const people = map({ m1: { nickname: "=evil", mergeInto: "" } });
  const model = S.computePlan(mkData({ limits: [current("a", "m1", "Max", 10, 3, { domain: "-x.com" })], people }), NOW, "Asia/Seoul");
  S.renderPlan(sheet, model, NOW, "Asia/Seoul");
  assert.equal(sheet.getRange(8, 1).getValues()[0][0], "=evil");
  assert.equal(sheet.getRange(8, 5).getValues()[0][0], "-x.com");
  assert.equal(sheet.getRange(30, 1).getValues()[0][0], "");
  assert.equal(sheet.getRange(8, 6).getValues()[0][0], 10);
});

test("an account nobody has read for 15 days is gone from rows and tiles; 13 days stays", () => {
  const stale = current("a1", "m1", "Max", 100, 2.5, { ageH: 15 * 24 });
  const fresh13 = current("a2", "m2", "Max", 100, 2.5, { ageH: 13 * 24 });
  const model = plan(mkData({ limits: [stale, fresh13] }));
  assert.deepEqual(model.rows.map((r) => r.nickname), ["지아"]);
  assert.equal(model.tiles.short, 1);
  assert.equal(model.excludedAccounts, 0);
});

function usageRow(memberId, date, team, total) { return { memberId, date, tool: "claude_code", team, total }; }

test("a person's department is the dashboard team over the last 28 days, not the latest limit row's team", () => {
  const usage = [
    usageRow("m1", "2026-11-10", "t2", 5), usageRow("m1", "2026-11-11", "t2", 5), usageRow("m1", "2026-11-12", "t2", 5),
    usageRow("m1", "2026-11-13", "t1", 50),
  ];
  const model = plan(mkData({
    usage, limits: [current("a1", "m1", "Max", 50, 2.5, { team: "t1" })],
    depts: map({ t1: { name: "A팀", suggested: "" }, t2: { name: "B팀", suggested: "" } }),
  }));
  assert.equal(model.rows[0].team, "B팀");
});

test("usage older than 28 days is ignored: fall back to the limit row's department", () => {
  const usage = [usageRow("m1", "2026-10-01", "t2", 5), usageRow("m1", "2026-10-02", "t2", 5)];
  const model = plan(mkData({
    usage, limits: [current("a1", "m1", "Max", 50, 2.5, { team: "t1" })],
    depts: map({ t1: { name: "A팀", suggested: "" }, t2: { name: "B팀", suggested: "" } }),
  }));
  assert.equal(model.rows[0].team, "A팀");
});

test("renderPlan sets explicit column widths", () => {
  const sheet = S.fakes.ss.insertSheet("플랜");
  S.renderPlan(sheet, plan(mkData({ limits: mockLimits() })), NOW, "Asia/Seoul");
  for (let c = 1; c <= 13; c++) assert.ok(sheet._widths[c] >= 70, `col ${c}`);
});
