"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { loadScript, DEFAULT_NOW_MS } = require("./harness.js");

const TZ = "Asia/Seoul";
const NOW = DEFAULT_NOW_MS;
const MEMBER = "8F1C2A4E-3B5D-4C6E-9A7B-1D2E3F4A5B6C";

function plain(v) { return JSON.parse(JSON.stringify(v)); }
function fresh() {
  const S = loadScript({ nowMs: NOW });
  return { S, ss: S.fakes.ss };
}
function body(ss, tab) {
  const sheet = ss.getSheetByName(tab);
  const last = sheet.getLastRow();
  return last < 2 ? [] : plain(sheet.getRange(2, 1, last - 1, sheet.getLastColumn()).getValues());
}

test("setup creates 14 tabs and one hourly trigger, and is idempotent", () => {
  const { S, ss } = fresh();
  S.setup();
  assert.equal(ss.getSheets().length, 14);
  assert.equal(S.fakes.triggers.length, 1);
  assert.equal(S.fakes.triggers[0].getHandlerFunction(), "refreshAll");
  S.setup();
  assert.equal(ss.getSheets().length, 14);
  assert.equal(S.fakes.triggers.length, 1);
});

test("setup replaces an older refreshAll trigger and keeps other triggers", () => {
  const { S } = fresh();
  S.ScriptApp.newTrigger("refreshAll").timeBased().everyHours(1).create();
  S.ScriptApp.newTrigger("refreshAll").timeBased().everyHours(1).create();
  S.ScriptApp.newTrigger("other").timeBased().everyHours(1).create();
  S.setup();
  const handlers = S.fakes.triggers.map((t) => t.getHandlerFunction()).sort();
  assert.deepEqual(handlers, ["other", "refreshAll"]);
});

test("seed then refresh fills the dashboard and the plan; every sample key uses the exact prefixes", () => {
  const { S, ss } = fresh();
  S.setup();
  S.seedSampleData();
  const month = ss.getSheetByName("이번 달");
  assert.ok(month.getRange(5, 1).getValues()[0][0] > 0);
  const plan = ss.getSheetByName("플랜");
  assert.ok(plan.getLastRow() >= 8, "plan has rows from row 8");
  const people = body(ss, "사람");
  assert.ok(people.length >= 12);
  people.forEach((r) => assert.match(r[0], /^00000000-0000-4000-8000-[0-9a-f]{12}$/));
  body(ss, "부서").forEach((r) => { assert.match(r[0], /^t_sample_/); assert.ok(r[1], "department named"); });
  assert.equal(new Set(body(ss, "부서").map((r) => r[1])).size, 4);
  body(ss, "한도").forEach((r) => assert.match(r[0], /^sample_/));
  body(ss, "원본").forEach((r) => assert.match(r[0], /^00000000-0000-4000-8000-/));
  // 5 weekly windows per account
  const perAccount = {};
  body(ss, "한도").forEach((r) => { const k = r[0] + "|" + r[1]; perAccount[k] = (perAccount[k] || 0) + 1; });
  Object.values(perAccount).forEach((n) => assert.equal(n, 5));
  // raw rows cover last month and this month
  const dates = new Set(body(ss, "원본").map((r) => r[2]));
  assert.ok([...dates].some((d) => d.startsWith("2026-10")));
  assert.ok([...dates].some((d) => d.startsWith("2026-11")));
});

test("seeding twice does not duplicate rows", () => {
  const { S, ss } = fresh();
  S.setup();
  S.seedSampleData();
  const n = body(ss, "원본").length;
  S.seedSampleData();
  assert.equal(body(ss, "원본").length, n);
  assert.equal(body(ss, "사람").length, 12);
});

test("clearSampleData leaves only real rows in every data tab", () => {
  const { S, ss } = fresh();
  const real = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "fixtures", "valid-two-accounts.json"), "utf8")).body;
  S.setup();
  S.seedSampleData();
  const res = plain(S.handleReport(ss, JSON.stringify(real), NOW, TZ));
  assert.equal(res.ok, true);
  const tabs = ["원본", "한도", "사람", "부서", "기기", "팀이름"];
  S.clearSampleData();
  const after = {};
  tabs.forEach((t) => { after[t] = body(ss, t); });
  assert.ok(after["원본"].length > 0 && after["사람"].length === 1 && after["기기"].length === 1);
  after["원본"].forEach((r) => assert.ok(!r[0].startsWith("00000000-0000-4000-8000-")));
  after["한도"].forEach((r) => assert.ok(!r[0].startsWith("sample_")));
  after["부서"].forEach((r) => assert.ok(!r[0].startsWith("t_sample_")));
  after["팀이름"].forEach((r) => assert.ok(!r[0].startsWith("t_sample_")));
  // 설정 untouched
  assert.equal(body(ss, "설정").length, 10);
  // a pure real-only sheet: clearing again changes nothing
  const snap = plain(tabs.map((t) => body(ss, t)));
  S.clearSampleData();
  assert.deepEqual(plain(tabs.map((t) => body(ss, t))), snap);
});

test("clearSampleData keeps a real row whose free text starts with a formula character", () => {
  const { S, ss } = fresh();
  S.setup();
  S.seedSampleData();
  ss.getSheetByName("사람").getRange(14, 1, 1, 6).setValues([[MEMBER, "'=지아", "2026-11-16T03:00:00.000Z", "", "2.5.640", "mac"]]);
  S.clearSampleData();
  const people = body(ss, "사람");
  assert.equal(people.length, 1);
  assert.equal(people[0][1], "=지아");
  assert.equal(ss.getSheetByName("사람")._rows[1][1], "=지아", "stored as text, not a formula");
});

test("refreshAll writes the most common team label, ties to the sorted first", () => {
  const { S, ss } = fresh();
  S.setup();
  const dept = ss.getSheetByName("부서");
  dept.getRange(2, 1, 2, 4).setValues([["t_aaaa", "", "", "2026-11-16"], ["t_bbbb", "", "", "2026-11-16"]]);
  const labels = ss.getSheetByName("팀이름");
  labels.getRange(2, 1, 6, 4).setValues([
    ["t_aaaa", "m1", "팀 1", "2026-11-16T00:00:00.000Z"],
    ["t_aaaa", "m2", "개발", "2026-11-16T00:00:00.000Z"],
    ["t_aaaa", "m3", "개발", "2026-11-16T00:00:00.000Z"],
    ["t_bbbb", "m1", "나", "2026-11-16T00:00:00.000Z"],
    ["t_bbbb", "m2", "가", "2026-11-16T00:00:00.000Z"],
    ["t_bbbb", "m3", "", "2026-11-16T00:00:00.000Z"],
  ]);
  S.refreshAll();
  const rows = body(ss, "부서");
  assert.equal(rows[0][2], "개발");
  assert.equal(rows[1][2], "가");
});

test("refreshAll skips the default team names when a member renamed the team, however many kept the default", () => {
  const { S, ss } = fresh();
  S.setup();
  const dept = ss.getSheetByName("부서");
  dept.getRange(2, 1, 2, 4).setValues([["t_cccc", "", "팀 1", "2026-11-16"], ["t_dddd", "", "", "2026-11-16"]]);
  const at = "2026-11-16T00:00:00.000Z";
  const labels = ss.getSheetByName("팀이름");
  labels.getRange(2, 1, 10, 4).setValues([
    ["t_cccc", "m1", "팀 1", at], ["t_cccc", "m2", "팀 1", at], ["t_cccc", "m3", "팀 1", at],
    ["t_cccc", "m4", "팀 1", at], ["t_cccc", "m5", "팀 2", at], ["t_cccc", "m6", "플랫폼본부", at],
    ["t_cccc", "m7", "플랫폼", at],
    ["t_dddd", "m1", "팀 2", at], ["t_dddd", "m2", "팀 1", at], ["t_dddd", "m3", "팀 1", at],
  ]);
  let rendered = null;
  const compute = S.computeDashboard;
  S.computeDashboard = (data, ...rest) => {
    rendered = rendered || { c: S.departmentOf("t_cccc", data.depts), d: S.departmentOf("t_dddd", data.depts) };
    return compute(data, ...rest);
  };
  S.refreshAll();
  const rows = body(ss, "부서");
  assert.equal(rows[0][2], "플랫폼", "a real name wins over five defaults; the tie between real names goes to the sorted first");
  assert.equal(rows[1][2], "팀 1", "a team with only default names still shows the most common one");
  assert.deepEqual(rendered, { c: "플랫폼", d: "" }, "the same refresh renders the new 참고팀이름");
});

test("refreshAll releases every lock, even when rendering throws", () => {
  const { S, ss } = fresh();
  S.setup();
  S.refreshAll();
  assert.equal(S.fakes.lockStats.released, S.fakes.lockStats.acquired);
  ss.getSheetByName("이번 달").getCharts = () => { throw new Error("boom"); };
  assert.throws(() => S.refreshAll(), /boom/);
  assert.equal(S.fakes.lockStats.released, S.fakes.lockStats.acquired);
});

test("onOpen builds the menu with seven items in order", () => {
  const { S } = fresh();
  S.onOpen({});
  assert.equal(S.fakes.menus.length, 1);
  assert.equal(S.fakes.menus[0].title, "사용량 대시보드");
  assert.deepEqual(plain(S.fakes.menus[0].items), [
    ["지금 새로 고침", "refreshAll"], ["샘플 데이터 넣기", "seedSampleData"], ["샘플 데이터 지우기", "clearSampleData"],
    ["멤버 ID 기록 지우기", "purgeMemberPrompt"], ["팀 ID 기록 지우기", "purgeTeamPrompt"],
    ["Enterprise API 키 넣기", "setEnterpriseKey"], ["Enterprise API 키 지우기", "clearEnterpriseKey"],
  ]);
});

test("refreshAll does not hold the lock while rendering", () => {
  const { S, ss } = fresh();
  S.setup();
  S.seedSampleData();
  const heldDuring = [];
  ["이번 달", "지난 7일", "지난달", "플랜"].forEach((name) => {
    const sheet = ss.getSheetByName(name);
    const clear = sheet.clear.bind(sheet);
    sheet.clear = () => { heldDuring.push(S.fakes.lockStats.held); clear(); };
  });
  const acquiredBefore = S.fakes.lockStats.acquired;
  S.refreshAll();
  assert.deepEqual(heldDuring, [false, false, false, false]);
  assert.ok(S.fakes.lockStats.acquired > acquiredBefore, "the short locks are still taken");
  assert.equal(S.fakes.lockStats.held, false);
});

test("the 참고팀이름 write re-reads 부서 inside the lock and writes column C only", () => {
  const { S, ss } = fresh();
  S.setup();
  const labels = ss.getSheetByName("팀이름");
  labels._rows.push(["t_new", MEMBER, "신규", new Date(NOW).toISOString()]);
  const depts = ss.getSheetByName("부서");
  depts._rows.push(["t_old", "개발팀", "", "2026-11-01"]);
  // a report adds a department between refreshAll's read and its 참고팀이름 write
  const readAll = S.readAll;
  S.readAll = (...a) => {
    const r = readAll(...a);
    depts._rows.push(["t_new", "", "", "2026-11-16"]);
    return r;
  };
  S.refreshAll();
  const rows = body(ss, "부서");
  assert.deepEqual(rows.map((r) => [r[0], r[1], r[2]]), [["t_old", "개발팀", ""], ["t_new", "", "신규"]]);
});

test("setup puts the dashboards and the plan first, opens 이번 달 and drops the empty default tab", () => {
  const { S, ss } = fresh();
  assert.deepEqual(ss.getSheets().map((s) => s.getName()), ["시트1"]);
  S.setup();
  const names = ss.getSheets().map((s) => s.getName());
  assert.deepEqual(names.slice(0, 4), ["이번 달", "지난 7일", "지난달", "플랜"]);
  assert.equal(names.includes("시트1"), false);
  assert.equal(names.length, 14);
  assert.deepEqual(names.slice(4, 11), ["원본", "한도", "사람", "부서", "설정", "엔터프라이즈 원본", "엔터프라이즈 사람"]);
  assert.equal(ss.getActiveSheet().getName(), "이번 달");
});

test("setup keeps a default tab that has data", () => {
  const { S, ss } = fresh();
  ss.getSheetByName("시트1")._rows.push(["내 메모"]);
  S.setup();
  assert.equal(ss.getSheetByName("시트1") !== null, true);
});

test("removeSampleRows writes the kept rows first and only clears the tail", () => {
  const { S, ss } = fresh();
  S.setup();
  S.seedSampleData();
  const real = [MEMBER, "진짜", new Date(NOW).toISOString(), "", "2.5.0", "mac"];
  const people = ss.getSheetByName("사람");
  people._rows.splice(1, 0, real);   // a real row in front of the samples
  const total = people._rows.length - 1;
  people._ops.length = 0;
  S.removeSampleRows(ss);
  assert.equal(people._ops[0][0], "set");
  assert.equal(people._ops[0][1], 2);
  assert.deepEqual(people._ops[1], ["clear", 3, total - 1]);
  assert.equal(people._ops.length, 2);
  assert.deepEqual(body(ss, "사람").map((r) => r[0]), [MEMBER]);
});

test("two refreshes never overlap: refreshAll holds the document lock, not the script lock, while rendering", () => {
  const { S, ss } = fresh();
  S.setup();
  const sheet = ss.getSheetByName("이번 달");
  const clear = sheet.clear.bind(sheet);
  let seen = null;
  sheet.clear = () => { seen = [S.fakes.lockStats.docHeld, S.fakes.lockStats.held]; clear(); };
  S.refreshAll();
  assert.deepEqual(seen, [true, false]);
  assert.equal(S.fakes.lockStats.docHeld, false);
  // a second refresh started while one renders would wait; the fake lock throws instead
  sheet.clear = () => { S.refreshAll(); };
  assert.throws(() => S.refreshAll(), /already held/);
  sheet.clear = clear;
  S.refreshAll();   // the lock was released after the throw
});

const REAL_ENT_USER = "user_real_01HZ";

test("every dashboard chart sets one header row (the empty 부서 bar in real Sheets)", () => {
  const { S, ss } = fresh();
  S.setup();
  S.seedSampleData();
  let charts = 0;
  ["이번 달", "지난 7일", "지난달"].forEach((name) => {
    ss.getSheetByName(name).getCharts().forEach((c) => { charts++; assert.equal(c.numHeaders, 1); });
  });
  assert.ok(charts >= 9, "two team charts and one Enterprise chart on each dashboard");
});

test("seed fills the Enterprise section and gives the plan one up and one down suggestion", () => {
  const { S, ss } = fresh();
  S.setup();
  S.seedSampleData();
  const rawRows = body(ss, "엔터프라이즈 원본");
  assert.ok(rawRows.length > 0);
  rawRows.forEach((r) => {
    assert.match(r[1], /^user_sample_/);
    assert.match(r[2], /^sample-ent-\d\d@sample\.example$/);
  });
  const dates = rawRows.map((r) => r[0]).sort();
  assert.equal(dates[0], "2026-09-01", "starts at the backfill start (prevStart of lastMonth)");
  assert.equal(dates[dates.length - 1], "2026-11-15", "ends yesterday, UTC");
  const ppl = body(ss, "엔터프라이즈 사람");
  assert.equal(ppl.length, 9);
  assert.equal(ppl.filter((r) => r[2] === "").length, 1);
  const ent = S.readAll(ss, TZ).enterprise;
  ["thisMonth", "last7", "lastMonth"].forEach((kind) => {
    const m = plain(S.computeEnterpriseSection(ent, kind, "2026-11-16"));
    assert.equal(m.hasData, true, kind);
    assert.ok(m.depts.length >= 3, kind);
    assert.ok(m.unassigned.people >= 1 && m.unassigned.messages > 0, kind);
  });
  const sheet = ss.getSheetByName("플랜");
  const cells = plain(sheet.getRange(1, 1, sheet.getLastRow(), 13).getValues()).flat().map(String);
  assert.ok(cells.some((c) => c.startsWith("올리기 검토")));
  assert.ok(cells.some((c) => c.startsWith("내리기 검토")));
});

test("clearSampleData removes every user_sample_ row and keeps a real Enterprise row", () => {
  const { S, ss } = fresh();
  S.setup();
  S.seedSampleData();
  const raw = ss.getSheetByName("엔터프라이즈 원본");
  raw.getRange(raw.getLastRow() + 1, 1, 1, 8).setValues([["2026-11-14", REAL_ENT_USER, "real@x.com", 5, 1, 0, 0, "2026-11-15T01:00:00.000Z"]]);
  const peopleTab = ss.getSheetByName("엔터프라이즈 사람");
  peopleTab.getRange(peopleTab.getLastRow() + 1, 1, 1, 4).setValues([[REAL_ENT_USER, "real@x.com", "개발", "2026-11-15"]]);
  S.clearSampleData();
  assert.deepEqual(body(ss, "엔터프라이즈 원본").map((r) => r[1]), [REAL_ENT_USER]);
  assert.deepEqual(body(ss, "엔터프라이즈 사람").map((r) => r[0]), [REAL_ENT_USER]);
});

test("seeding twice keeps one set of Enterprise sample rows", () => {
  const { S, ss } = fresh();
  S.setup();
  S.seedSampleData();
  const n = body(ss, "엔터프라이즈 원본").length;
  S.seedSampleData();
  assert.equal(body(ss, "엔터프라이즈 원본").length, n);
  assert.equal(body(ss, "엔터프라이즈 사람").length, 9);
});

test("setup trims every data tab to its width and leaves dashboards and the plan at 26 columns", () => {
  const { S, ss } = fresh();
  S.setup();
  S.TAB_SPECS.forEach((spec) => {
    assert.equal(ss.getSheetByName(spec.name).getMaxColumns(), spec.cols.length, spec.name);
  });
  ["이번 달", "지난 7일", "지난달", "플랜"].forEach((n) => assert.equal(ss.getSheetByName(n).getMaxColumns(), 26, n));
  S.setup();   // idempotent: nothing left to delete
  S.TAB_SPECS.forEach((spec) => assert.equal(ss.getSheetByName(spec.name).getMaxColumns(), spec.cols.length));
});

test("setup leaves a data tab alone when it has content beyond its width", () => {
  const { S, ss } = fresh();
  S.ensureAllTabs(ss);
  const limits = ss.getSheetByName("한도");
  limits.getRange(2, 12).setValue("내 메모");
  S.setup();
  assert.equal(limits.getMaxColumns(), 26);
  assert.equal(limits.getRange(2, 12).getValues()[0][0], "내 메모");
  assert.equal(ss.getSheetByName("원본").getMaxColumns(), S.COLS_RAW.length, "other tabs are still trimmed");
});

// Owner purge: one member ID or team ID leaves every data tab; the others stay.
const OTHER = "11111111-2222-4333-8444-555555555555";
function reportFor(S, id, team, nick) {
  const b = JSON.parse(fs.readFileSync(path.join(__dirname, "..", "fixtures", "valid-basic.json"), "utf8")).body;
  b.member.id = id; b.member.nickname = nick;
  b.days.forEach((d) => { d.team = team; });
  b.limits.forEach((l) => { l.team = team; });
  assert.equal(plain(S.handleReport(S.fakes.ss, JSON.stringify(b), NOW, TZ)).ok, true);
}

test("purgeById removes one member's rows from every tab and leaves the other member", () => {
  const { S, ss } = fresh();
  reportFor(S, MEMBER, "t_keep", "남김");
  reportFor(S, OTHER, "t_other", "지움");
  const gone = plain(S.purgeById(ss, "member", OTHER));
  assert.deepEqual(Object.keys(gone).sort(), ["기기", "사람", "원본", "팀이름", "한도"].sort());
  for (const tab of ["원본", "한도", "사람", "기기", "팀이름"]) {
    assert.equal(JSON.stringify(body(ss, tab)).includes(OTHER), false, tab);
    assert.equal(JSON.stringify(body(ss, tab)).includes(MEMBER), true, tab);
  }
  // the member can register again afterwards
  reportFor(S, OTHER, "t_other", "지움");
  assert.equal(body(ss, "기기").length, 2);
});

test("purgeById removes one team ID from every tab it appears in", () => {
  const { S, ss } = fresh();
  reportFor(S, MEMBER, "t_keep", "남김");
  reportFor(S, OTHER, "t_other", "지움");
  const gone = plain(S.purgeById(ss, "team", "t_other"));
  assert.deepEqual(Object.keys(gone).sort(), ["부서", "원본", "팀이름", "한도"].sort());
  for (const tab of ["원본", "한도", "부서", "팀이름"]) {
    assert.equal(JSON.stringify(body(ss, tab)).includes("t_other"), false, tab);
    assert.equal(JSON.stringify(body(ss, tab)).includes("t_keep"), true, tab);
  }
});

test("purgeById refuses a malformed id and removes nothing", () => {
  const { S, ss } = fresh();
  reportFor(S, MEMBER, "t_keep", "남김");
  const before = JSON.stringify(body(ss, "원본"));
  assert.equal(S.purgeById(ss, "member", "t_keep"), null);
  assert.equal(S.purgeById(ss, "team", MEMBER), null);
  assert.equal(S.purgeById(ss, "member", ""), null);
  assert.equal(JSON.stringify(body(ss, "원본")), before);
});

test("the purge menu entry asks, purges under the lock and reports the counts", () => {
  const { S, ss } = fresh();
  reportFor(S, MEMBER, "t_keep", "남김");
  S.fakes.ui.next = { button: "OK", text: " " + MEMBER + " " };
  S.purgeMemberPrompt();
  assert.equal(body(ss, "원본").length, 0);
  assert.match(S.fakes.ui.alerts.at(-1), /원본: 3행/);
  S.fakes.ui.next = { button: "CANCEL", text: MEMBER };
  const n = S.fakes.ui.alerts.length;
  S.purgeMemberPrompt();
  assert.equal(S.fakes.ui.alerts.length, n);
});
