"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { loadScript } = require("./harness.js");

const S = loadScript();
function plain(v) { return JSON.parse(JSON.stringify(v)); }
function range(kind, today) { return plain(S.periodRange(kind, today)); }
function pick(r) { return [r.start, r.end, r.prevStart, r.prevEnd]; }

function people(map) {
  const o = Object.create(null);
  Object.keys(map).forEach((k) => { o[k] = map[k]; });
  return o;
}
function mkData(over) {
  return Object.assign({
    usage: [], limits: [], people: people({}), depts: people({}), teamLabels: [], settings: {},
  }, over);
}
function row(memberId, date, team, total, tool) {
  return { memberId, date, tool: tool || "claude_code", team, total };
}
const TODAY = "2026-11-16";

test("periodRange: month boundaries (Review Focus 4)", () => {
  assert.deepEqual(pick(range("thisMonth", "2026-11-16")), ["2026-11-01", "2026-11-16", "2026-10-01", "2026-10-16"]);
  assert.deepEqual(pick(range("thisMonth", "2026-03-31")), ["2026-03-01", "2026-03-31", "2026-02-01", "2026-02-28"]);
  assert.deepEqual(pick(range("thisMonth", "2028-03-31")), ["2028-03-01", "2028-03-31", "2028-02-01", "2028-02-29"]);
  assert.deepEqual(pick(range("thisMonth", "2026-11-01")), ["2026-11-01", "2026-11-01", "2026-10-01", "2026-10-01"]);
  assert.deepEqual(pick(range("thisMonth", "2027-01-01")), ["2027-01-01", "2027-01-01", "2026-12-01", "2026-12-01"]);
  assert.deepEqual(pick(range("lastMonth", "2027-01-01")), ["2026-12-01", "2026-12-31", "2026-11-01", "2026-11-30"]);
  assert.deepEqual(pick(range("lastMonth", "2026-03-15")), ["2026-02-01", "2026-02-28", "2026-01-01", "2026-01-31"]);
  assert.deepEqual(pick(range("last7", "2026-11-16")), ["2026-11-10", "2026-11-16", "2026-11-03", "2026-11-09"]);
  assert.deepEqual(pick(range("last7", "2026-01-03")), ["2025-12-28", "2026-01-03", "2025-12-21", "2025-12-27"]);
  assert.equal(range("thisMonth", TODAY).title, "이번 달 (2026-11-01 ~ 2026-11-16)");
});

test("canonicalPerson: hops, cycles, missing targets", () => {
  const ppl = people({
    a: { nickname: "A", mergeInto: "b" }, b: { nickname: "B", mergeInto: "" },
    c: { nickname: "C", mergeInto: "d" }, d: { nickname: "D", mergeInto: "c" },
    e: { nickname: "E", mergeInto: "ghost" }, f: { nickname: "F", mergeInto: "f" },
  });
  assert.equal(S.canonicalPerson("a", ppl), "b");
  assert.equal(S.canonicalPerson("b", ppl), "b");
  assert.equal(S.canonicalPerson("c", ppl), "c");
  assert.equal(S.canonicalPerson("d", ppl), "d");
  assert.equal(S.canonicalPerson("e", ppl), "e");
  assert.equal(S.canonicalPerson("f", ppl), "f");
  const tail = people({ x: { mergeInto: "y" }, y: { mergeInto: "z" }, z: { mergeInto: "y" } });
  assert.equal(S.canonicalPerson("x", tail), "x"); // enters a cycle it is not part of
  const long = people({ p0: { mergeInto: "p1" }, p1: { mergeInto: "p2" }, p2: { mergeInto: "p3" }, p3: { mergeInto: "p4" },
    p4: { mergeInto: "p5" }, p5: { mergeInto: "p6" }, p6: { mergeInto: "" } });
  assert.equal(S.canonicalPerson("p0", long), "p5"); // stops after 5 hops
  assert.equal(S.canonicalPerson("nobody", ppl), "nobody");
  assert.equal(S.canonicalPerson("__proto__", ppl), "__proto__");
});

test("departmentOf: trimmed name or empty", () => {
  const d = people({ t1: { name: "개발팀", suggested: "" }, t2: { name: "", suggested: "x" } });
  assert.equal(S.departmentOf("t1", d), "개발팀");
  assert.equal(S.departmentOf("t2", d), "");
  assert.equal(S.departmentOf("nope", d), "");
  assert.equal(S.departmentOf("constructor", d), "");
});

function mockData() {
  const depts = people({
    t_dev: { name: "개발팀", suggested: "" }, t_edu: { name: "교육운영팀", suggested: "" },
    t_des: { name: "디자인팀", suggested: "" }, t_biz: { name: "사업팀", suggested: "" },
  });
  const usage = [];
  const ppl = people({});
  const spec = [["t_dev", 12, 3840e6], ["t_edu", 18, 1620e6], ["t_des", 6, 720e6], ["t_biz", 9, 540e6]];
  spec.forEach(([team, n, total]) => {
    for (let i = 0; i < n; i++) {
      const id = `${team}-${i}`;
      ppl[id] = { nickname: id, mergeInto: "" };
      usage.push(row(id, "2026-11-05", team, total / n));
    }
  });
  return mkData({ usage, people: ppl, depts });
}

test("mock numbers", () => {
  const m = plain(S.computeDashboard(mockData(), "thisMonth", TODAY));
  assert.equal(m.tiles.people, 45);
  assert.equal(m.tiles.teamCount, 4);
  assert.equal(Math.round(m.tiles.total), 6720e6);
  assert.ok(Math.abs(m.tiles.perPerson - 6720e6 / 45) < 1);
  assert.deepEqual(m.teams.map((t) => [t.name, t.people]), [["개발팀", 12], ["교육운영팀", 18], ["디자인팀", 6], ["사업팀", 9]]);
  assert.equal(Math.round(m.teams[0].total), 3840e6);
  assert.equal(m.tiles.deltaTotalPct, null);
  assert.equal(m.title, "이번 달 (2026-11-01 ~ 2026-11-16)");
});

test("unassigned rows are excluded and counted", () => {
  const d = mkData({
    usage: [row("m1", "2026-11-02", "t1", 100), row("m2", "2026-11-02", "t_x", 50), row("m3", "2026-11-02", "t_blank", 70)],
    depts: people({ t1: { name: "개발팀", suggested: "" }, t_blank: { name: "", suggested: "" } }),
    people: people({ m1: { nickname: "지아", mergeInto: "" } }),
  });
  const m = plain(S.computeDashboard(d, "thisMonth", TODAY));
  assert.equal(m.tiles.total, 100);
  assert.equal(m.tiles.people, 1);
  assert.deepEqual(m.unassigned, { people: 2, total: 120 });
  assert.equal(m.top.length, 1);
  assert.equal(m.top[0].nickname, "지아");
  assert.equal(m.bottom.length, 0);
});

test("same-named departments combine; rows out of range ignored", () => {
  const d = mkData({
    usage: [row("m1", "2026-11-02", "t1", 100), row("m2", "2026-11-03", "t2", 50),
      row("m3", "2026-10-31", "t1", 999), row("m4", "2026-11-17", "t1", 999)],
    depts: people({ t1: { name: "개발팀", suggested: "" }, t2: { name: " 개발팀 ", suggested: "" } }),
  });
  const m = plain(S.computeDashboard(d, "thisMonth", TODAY));
  assert.equal(m.teams.length, 1);
  assert.deepEqual([m.teams[0].name, m.teams[0].total, m.teams[0].people], ["개발팀", 150, 2]);
  assert.equal(m.tiles.teamCount, 1);
});

test("merged person counts once with the summed total; nickname from canonical", () => {
  const d = mkData({
    usage: [row("aaaaaaaa-1111", "2026-11-02", "t1", 100), row("bbbbbbbb-2222", "2026-11-03", "t1", 40)],
    depts: people({ t1: { name: "개발팀", suggested: "" } }),
    people: people({
      "aaaaaaaa-1111": { nickname: "옛날", mergeInto: "bbbbbbbb-2222" },
      "bbbbbbbb-2222": { nickname: "지아", mergeInto: "" },
    }),
  });
  const m = plain(S.computeDashboard(d, "thisMonth", TODAY));
  assert.equal(m.tiles.people, 1);
  assert.equal(m.top.length, 1);
  assert.deepEqual([m.top[0].nickname, m.top[0].total], ["지아", 140]);
});

test("cycle and missing target keep each id as itself; nickname falls back to 8 chars", () => {
  const d = mkData({
    usage: [row("abcdefgh-1", "2026-11-02", "t1", 10), row("ijklmnop-2", "2026-11-02", "t1", 20), row("qrstuvwx-3", "2026-11-02", "t1", 30)],
    depts: people({ t1: { name: "개발팀", suggested: "" } }),
    people: people({
      "abcdefgh-1": { nickname: "A", mergeInto: "ijklmnop-2" },
      "ijklmnop-2": { nickname: "B", mergeInto: "abcdefgh-1" },
      "qrstuvwx-3": { nickname: "", mergeInto: "ghost" },
    }),
  });
  const m = plain(S.computeDashboard(d, "thisMonth", TODAY));
  assert.equal(m.tiles.people, 3);
  assert.deepEqual(m.top.map((p) => p.nickname), ["qrstuvwx", "B", "A"]);
});

test("zero rows count as people and show in bottom with 0", () => {
  const usage = [];
  for (let i = 1; i <= 6; i++) usage.push(row(`m${i}`, "2026-11-02", "t1", i * 10));
  usage.push(row("m0", "2026-11-02", "t1", 0, "-"));
  const d = mkData({ usage, depts: people({ t1: { name: "개발팀", suggested: "" } }) });
  const m = plain(S.computeDashboard(d, "thisMonth", TODAY));
  assert.equal(m.tiles.people, 7);
  assert.equal(m.top.length, 5);
  assert.equal(m.bottom.length, 2);
  assert.deepEqual(m.bottom.map((p) => p.total), [0, 10]);
  const topIds = new Set(m.top.map((p) => p.nickname));
  m.bottom.forEach((p) => assert.ok(!topIds.has(p.nickname)));
  // 3 people: all in top, bottom empty
  const d3 = mkData({ usage: usage.slice(0, 3), depts: d.depts });
  const m3 = plain(S.computeDashboard(d3, "thisMonth", TODAY));
  assert.equal(m3.top.length, 3);
  assert.equal(m3.bottom.length, 0);
});

test("top ties break by nickname ascending", () => {
  const d = mkData({
    usage: [row("m1", "2026-11-02", "t1", 10), row("m2", "2026-11-02", "t1", 10)],
    depts: people({ t1: { name: "개발팀", suggested: "" } }),
    people: people({ m1: { nickname: "나", mergeInto: "" }, m2: { nickname: "가", mergeInto: "" } }),
  });
  const m = plain(S.computeDashboard(d, "thisMonth", TODAY));
  assert.deepEqual(m.top.map((p) => p.nickname), ["가", "나"]);
});

test("person's team: more days, then more tokens, then name", () => {
  const depts = people({ ta: { name: "가팀", suggested: "" }, tb: { name: "나팀", suggested: "" } });
  const pp = people({ m1: { nickname: "x", mergeInto: "" } });
  const team = (usage) => plain(S.computeDashboard(mkData({ usage, depts, people: pp }), "thisMonth", TODAY)).top[0].team;
  // more days wins even with fewer tokens
  assert.equal(team([row("m1", "2026-11-01", "ta", 1), row("m1", "2026-11-02", "ta", 1), row("m1", "2026-11-03", "tb", 1000)]), "가팀");
  // same days: more tokens
  assert.equal(team([row("m1", "2026-11-01", "ta", 1), row("m1", "2026-11-02", "tb", 5)]), "나팀");
  // same days and tokens: name ascending
  assert.equal(team([row("m1", "2026-11-01", "tb", 5), row("m1", "2026-11-02", "ta", 5)]), "가팀");
});

test("deltas: percent change, null on zero comparison, people difference", () => {
  const depts = people({ t1: { name: "개발팀", suggested: "" } });
  const usage = [
    row("m1", "2026-11-02", "t1", 118), row("m2", "2026-11-02", "t1", 0, "-"),
    row("m1", "2026-10-02", "t1", 100),
    row("m1", "2026-10-20", "t1", 9999), // after prevEnd (10-16), ignored
  ];
  const m = plain(S.computeDashboard(mkData({ usage, depts }), "thisMonth", TODAY));
  assert.equal(m.tiles.deltaTotalPct, 18);
  assert.equal(m.tiles.deltaPeople, 1);
  assert.equal(m.tiles.deltaPerPersonPct, -41);
  const none = plain(S.computeDashboard(mkData({ usage: [row("m1", "2026-11-02", "t1", 5)], depts }), "thisMonth", TODAY));
  assert.equal(none.tiles.deltaTotalPct, null);
  assert.equal(none.tiles.deltaPerPersonPct, null);
});

test("empty data does not divide by zero", () => {
  const m = plain(S.computeDashboard(mkData(), "last7", TODAY));
  assert.deepEqual(m.tiles, { total: 0, perPerson: 0, people: 0, teamCount: 0, deltaTotalPct: null, deltaPerPersonPct: null, deltaPeople: 0 });
  assert.deepEqual(m.teams, []);
});

// ---- rendering ----
function renderOn(model, sheetOpts) {
  const R = loadScript();
  const sheet = R.fakes.ss.insertSheet("이번 달");
  if (sheetOpts && sheetOpts.maxRows) sheet._maxRows = sheetOpts.maxRows;
  R.renderDashboard(sheet, model, R.nowMs, R.tz);
  return { R, sheet };
}
function cell(sheet, r, c) { return (sheet._rows[r - 1] || [])[c - 1]; }

test("renderDashboard layout, delta text and charts", () => {
  const R = loadScript();
  const model = R.computeDashboard(mockData(), "thisMonth", TODAY);
  const sheet = R.fakes.ss.insertSheet("이번 달");
  R.renderDashboard(sheet, model, R.nowMs, R.tz);
  assert.equal(cell(sheet, 1, 1), "이번 달 (2026-11-01 ~ 2026-11-16)");
  assert.equal(cell(sheet, 2, 1), "마지막 갱신: 2026-11-16 12:00");
  assert.deepEqual([1, 2, 3, 4].map((c) => cell(sheet, 4, c)), ["전체 토큰", "1인 평균", "쓰는 사람", "팀 수"]);
  assert.equal(Math.round(cell(sheet, 5, 1)), 6720e6);
  assert.equal(cell(sheet, 5, 3), 45);
  assert.deepEqual([1, 2, 3, 4].map((c) => cell(sheet, 8, c)), ["부서", "총 토큰", "1인 평균", "인원"]);
  assert.equal(cell(sheet, 9, 1), "개발팀");
  assert.equal(cell(sheet, 12, 1), "사업팀");
  assert.equal(cell(sheet, 6, 1), "—");
  assert.equal(cell(sheet, 6, 3), "+45명");
  assert.deepEqual([6, 7, 8].map((c) => cell(sheet, 8, c)), ["많이 쓰는 팀원", "부서", "토큰"]);
  assert.deepEqual([6, 7, 8].map((c) => cell(sheet, 16, c)), ["적게 쓰는 팀원", "부서", "토큰"]);
  assert.equal(cell(sheet, 23, 1), "미지정: 0명 · 0.0M 토큰 — 부서 탭에 이름을 적으면 포함됩니다");
  assert.equal(sheet._formats[2], '#,##0.0,,"M"');
  const charts = sheet.getCharts();
  assert.equal(charts.length, 2);
  charts.forEach((c) => {
    assert.ok(c.ranges.length >= 2);
    c.ranges.forEach((a) => { assert.equal(a.row, 8); assert.equal(a.row + a.numRows - 1, 12); });
    assert.equal(c.chartType, "BAR");
  });
  // second render replaces, not adds
  R.renderDashboard(sheet, model, R.nowMs, R.tz);
  assert.equal(sheet.getCharts().length, 2);
});

test("delta texts", () => {
  const R = loadScript();
  assert.equal(R.formatDeltaPct(18), "+18.0%");
  assert.equal(R.formatDeltaPct(-6), "-6.0%");
  assert.equal(R.formatDeltaPct(0), "0.0%");
  assert.equal(R.formatDeltaPct(null), "—");
  assert.equal(R.formatDeltaPeople(4), "+4명");
  assert.equal(R.formatDeltaPeople(-2), "-2명");
  assert.equal(R.formatDeltaPeople(0), "0명");
});

test("render with no teams adds no charts; grows a small sheet instead of throwing", () => {
  const R = loadScript();
  const empty = R.computeDashboard(mkData(), "last7", TODAY);
  const a = R.fakes.ss.insertSheet("지난 7일");
  R.renderDashboard(a, empty, R.nowMs, R.tz);
  assert.equal(a.getCharts().length, 0);
  assert.equal(cell(a, 9, 1) === undefined || cell(a, 9, 1) === "", true);

  const big = mockData();
  const { sheet } = renderOn(R.computeDashboard(big, "thisMonth", TODAY), { maxRows: 12 });
  assert.ok(sheet.getMaxRows() > 12);
  assert.equal(cell(sheet, 12, 1), "사업팀");
});

test("render stays inside 1000 rows with many departments", () => {
  const depts = people({});
  const usage = [];
  for (let i = 0; i < 1100; i++) {
    depts[`t${i}`] = { name: `부서${i}`, suggested: "" };
    usage.push(row(`m${i}`, "2026-11-02", `t${i}`, i + 1));
  }
  const R = loadScript();
  const model = R.computeDashboard(mkData({ usage, depts }), "thisMonth", TODAY);
  const sheet = R.fakes.ss.insertSheet("이번 달");
  R.renderDashboard(sheet, model, R.nowMs, R.tz);
  assert.equal(model.teams.length, 1100);
  assert.equal(cell(sheet, 8 + 1100, 1) !== undefined, true);
});

// ---- text written as text (Sheets would parse formulas and numbers) ----
function readBack(sheet, r, c) { return sheet.getRange(r, c).getValues()[0][0]; }

test("render writes peer text and deltas as exact text", () => {
  const R = loadScript();
  const d = mkData({
    usage: [row("m1", "2026-11-02", "t1", 100), row("m1", "2026-10-02", "t1", 85)],
    depts: people({ t1: { name: "=SUM(1)", suggested: "" } }),
    people: people({ m1: { nickname: "-지아", mergeInto: "" } }),
  });
  const model = R.computeDashboard(d, "thisMonth", TODAY);
  const sheet = R.fakes.ss.insertSheet("이번 달");
  R.renderDashboard(sheet, model, R.nowMs, R.tz);
  assert.equal(readBack(sheet, 9, 1), "=SUM(1)");
  assert.equal(readBack(sheet, 9, 6), "-지아");
  assert.equal(readBack(sheet, 9, 7), "=SUM(1)");
  assert.equal(readBack(sheet, 6, 1), "+17.6%");
  assert.equal(readBack(sheet, 6, 3), "0명");
});

test("charts: titles, sizes, side-by-side positions, chart 2 sorted by 1인 평균", () => {
  const R = loadScript();
  const model = R.computeDashboard(mockData(), "thisMonth", TODAY);
  const sheet = R.fakes.ss.insertSheet("이번 달");
  R.renderDashboard(sheet, model, R.nowMs, R.tz);
  const [c1, c2] = sheet.getCharts();
  assert.equal(c1.options.title, "팀별 총 사용량");
  assert.equal(c2.options.title, "팀별 1인 평균");
  [c1, c2].forEach((c) => {
    assert.equal(typeof c.options.width, "number");
    assert.equal(typeof c.options.height, "number");
    assert.equal(c.position.row, 4);
  });
  // side by side: the second starts to the right of where the first ends
  assert.ok(c2.position.offsetX >= c1.position.offsetX + c1.options.width);
  assert.equal(c1.position.col, c2.position.col);
  // chart 2 reads the sorted copy: per-person values descending
  const labels = c2.ranges[0], values = c2.ranges[1];
  assert.equal(labels.col, values.col - 1);
  const rows = sheet.getRange(values.row, values.col, values.numRows, 1).getValues().map((r) => r[0]).slice(1);
  assert.deepEqual(rows, rows.slice().sort((a, b) => b - a));
  const names = sheet.getRange(labels.row, labels.col, labels.numRows, 1).getValues().map((r) => r[0]).slice(1);
  const byName = new Map(model.teams.map((t) => [t.name, t.perPerson]));
  assert.deepEqual(rows, names.map((n) => byName.get(n)));
  assert.equal(new Set(rows).size > 1, true);
  // chart 1 keeps the table order (by total)
  const first = sheet.getRange(c1.ranges[0].row + 1, c1.ranges[0].col, 1, 1).getValues()[0][0];
  assert.equal(first, model.teams[0].name);
});

test("notes sit below both the team table and the F:H tables", () => {
  const depts = people({});
  const usage = [];
  for (let i = 0; i < 4; i++) {
    depts[`t${i}`] = { name: `부서${i}`, suggested: "" };
    for (let j = 0; j < 3; j++) usage.push(row(`m${i}_${j}`, "2026-11-02", `t${i}`, i * 3 + j + 1));
  }
  const R = loadScript();
  const model = R.computeDashboard(mkData({ usage, depts }), "thisMonth", TODAY);
  const sheet = R.fakes.ss.insertSheet("이번 달");
  R.renderDashboard(sheet, model, R.nowMs, R.tz);
  const personTableEnd = 16 + model.bottom.length;
  const noteRow = [...Array(60).keys()].map((i) => i + 1).find((r) => String(cell(sheet, r, 1)).startsWith("미지정"));
  assert.ok(noteRow > personTableEnd, `note at ${noteRow}, table ends ${personTableEnd}`);
  assert.equal(model.bottom.length > 0, true);
  assert.equal(String(cell(sheet, noteRow + 2, 1)).startsWith("앱이 없거나"), true);
  assert.equal(cell(sheet, personTableEnd, 6) !== "", true);   // the last person row is intact
});

test("columns get explicit widths after rendering", () => {
  const R = loadScript();
  const sheet = R.fakes.ss.insertSheet("이번 달");
  R.renderDashboard(sheet, R.computeDashboard(mockData(), "thisMonth", TODAY), R.nowMs, R.tz);
  [1, 2, 3, 4, 6, 7, 8].forEach((c) => assert.ok(sheet._widths[c] >= 90, `col ${c}`));
});
