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

test("setup creates 11 tabs and one hourly trigger, and is idempotent", () => {
  const { S, ss } = fresh();
  S.setup();
  assert.equal(ss.getSheets().length, 11);
  assert.equal(S.fakes.triggers.length, 1);
  assert.equal(S.fakes.triggers[0].getHandlerFunction(), "refreshAll");
  S.setup();
  assert.equal(ss.getSheets().length, 11);
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

test("refreshAll holds and releases the lock, even when rendering throws", () => {
  const { S, ss } = fresh();
  S.setup();
  S.refreshAll();
  assert.equal(S.fakes.lockStats.released, S.fakes.lockStats.acquired);
  ss.getSheetByName("이번 달").getCharts = () => { throw new Error("boom"); };
  assert.throws(() => S.refreshAll(), /boom/);
  assert.equal(S.fakes.lockStats.released, S.fakes.lockStats.acquired);
});

test("onOpen builds the menu with three items in order", () => {
  const { S } = fresh();
  S.onOpen({});
  assert.equal(S.fakes.menus.length, 1);
  assert.equal(S.fakes.menus[0].title, "사용량 대시보드");
  assert.deepEqual(plain(S.fakes.menus[0].items), [
    ["지금 새로 고침", "refreshAll"], ["샘플 데이터 넣기", "seedSampleData"], ["샘플 데이터 지우기", "clearSampleData"],
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
  assert.equal(names.length, 11);
  assert.deepEqual(names.slice(4, 9), ["원본", "한도", "사람", "부서", "설정"]);
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
