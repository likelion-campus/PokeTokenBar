"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { loadScript } = require("./harness.js");

const TZ = "Asia/Seoul";
const TODAY = "2026-11-16";
const KEY = "sk-ant-secret-KEY-123";
function plain(v) { return JSON.parse(JSON.stringify(v)); }
function fixture(name) { return JSON.parse(fs.readFileSync(path.join(__dirname, "..", "fixtures", "enterprise", name), "utf8")); }
function use(date, userId, email, chat, cowork, code) { return { date, userId, email, chat, conv: 1, cowork, code: code || 0 }; }
function people(map) {
  const o = Object.create(null);
  Object.keys(map).forEach((k) => { o[k] = map[k]; });
  return o;
}
function ent(usage, ppl, extra) {
  return Object.assign({ usage, people: people(ppl || {}), status: null, hasKey: true }, extra || {});
}
const S = loadScript();
function section(e, kind) { return plain(S.computeEnterpriseSection(e, kind || "thisMonth", TODAY)); }

const MANY = ent([
  use("2026-11-02", "a", "ada@x.com", 10, 5, 2),
  use("2026-11-03", "b", "bo@x.com", 18, 0, 1),
  use("2026-11-03", "c", "cy@x.com", 0, 0, 0),
  use("2026-11-03", "d", "", 30, 10, 4),
  use("2026-11-04", "e", "e@x.com", 1, 0, 0),
  use("2026-11-04", "f", "f@x.com", 2, 0, 0),
  use("2026-11-04", "g", "g@x.com", 3, 0, 0),
  use("2026-11-04", "h", "h@x.com", 4, 0, 0),
  use("2026-11-05", "u", "ufo@x.com", 100, 0, 9),
  use("2026-10-05", "a", "ada@x.com", 10, 0, 0),
  use("2026-09-30", "a", "ada@x.com", 999, 0, 0),
  use("2026-11-17", "a", "ada@x.com", 999, 0, 0),
], {
  a: { email: "ada@x.com", dept: "개발" }, b: { email: "bo@x.com", dept: "개발" },
  c: { email: "cy@x.com", dept: "교육" }, d: { email: "", dept: "교육" },
  e: { email: "e@x.com", dept: "운영" }, f: { email: "f@x.com", dept: "운영" },
  g: { email: "g@x.com", dept: "운영" }, h: { email: "h@x.com", dept: "운영" },
  u: { email: "ufo@x.com", dept: "" },
});

test("computeEnterpriseSection: period bounds, tiles, deltas and unassigned", () => {
  const m = section(MANY);
  assert.equal(m.hasData, true);
  // assigned users with a row in 11-01..11-16: a 15, b 18, c 0, d 40, e 1, f 2, g 3, h 4 = 83 over 8 people
  assert.equal(m.tiles.messages, 83);
  assert.equal(m.tiles.people, 8);
  assert.equal(m.tiles.perPerson, 83 / 8);
  assert.equal(m.tiles.deptCount, 3);
  // prev 10-01..10-16: only a with 10 messages
  assert.equal(m.tiles.deltaMessagesPct, S.pctChange(83, 10));
  assert.equal(m.tiles.deltaPerPersonPct, S.pctChange(83 / 8, 10));
  assert.equal(m.tiles.deltaPeople, 7);
  assert.deepEqual(m.unassigned, { people: 1, messages: 100 });
});

test("computeEnterpriseSection: departments sort by messages then name", () => {
  const m = section(MANY);
  assert.deepEqual(m.depts.map((d) => [d.name, d.messages, d.people]), [["교육", 40, 2], ["개발", 33, 2], ["운영", 10, 4]]);
  assert.equal(m.depts[0].perPerson, 20);
});

test("computeEnterpriseSection: top and bottom never overlap, names come from the email, 0-message users count", () => {
  const m = section(MANY);
  assert.deepEqual(m.top.map((p) => p.name), ["d", "bo", "ada", "h", "g"]);   // d has no email: the userId
  assert.deepEqual(m.top[0], { name: "d", dept: "교육", messages: 40, code: 4 });
  assert.deepEqual(m.bottom.map((p) => p.name), ["cy", "e", "f"]);
  assert.equal(m.bottom[0].messages, 0);
  const names = new Set(m.top.map((p) => p.name));
  m.bottom.forEach((p) => assert.ok(!names.has(p.name)));
  assert.ok(![...m.top, ...m.bottom].some((p) => p.name === "ufo"), "unassigned users are in neither list");
});

test("computeEnterpriseSection: a member who switched to unified metrics keeps continuous totals", () => {
  const p1 = fixture("users-page1.json");
  const rows = p1.data.map((r) => S.entRecordToRow(r, "2026-11-14", "NOW")).filter(Boolean).map(plain);
  const usage = rows.map((r) => ({ date: r[0], userId: r[1], email: r[2], chat: r[3], conv: r[4], cowork: r[5], code: r[6] }));
  const ppl = {};
  usage.forEach((u) => { ppl[u.userId] = { email: u.email, dept: "개발" }; });
  const m = section(ent(usage, ppl));
  const bo = m.top.concat(m.bottom).find((p) => p.name === "bo");
  assert.equal(bo.messages, 12 + 6);
  assert.equal(bo.code, 1);
});

test("computeEnterpriseSection: empty and out-of-period data has no data", () => {
  assert.equal(section(ent([])).hasData, false);
  assert.equal(section(ent([use("2026-09-01", "a", "a@x", 1, 1)], { a: { email: "a@x", dept: "개발" } })).hasData, false);
});

test("computeEnterpriseSection: last7 uses its own range", () => {
  const m = section(ent([use("2026-11-10", "a", "a@x", 5, 0), use("2026-11-09", "a", "a@x", 50, 0)], { a: { email: "a@x", dept: "개발" } }), "last7");
  assert.equal(m.tiles.messages, 5);
});

test("enterpriseStatusLine: the three variants and the error suffix", () => {
  const line = (st, key) => S.enterpriseStatusLine(st, key, TZ);
  assert.equal(line(null, false), "Enterprise 키가 없습니다 — 메뉴 > Enterprise API 키 넣기");
  assert.equal(line(null, true), "아직 불러오지 못했습니다");
  assert.equal(line({ lastRunMs: Date.parse("2026-11-16T03:00:00Z"), newestDate: "2026-11-15", error: null }, true),
    "마지막 불러옴: 2026-11-16 12:00 · 데이터: 2026-11-15까지");
  assert.equal(line({ lastRunMs: Date.parse("2026-11-16T03:00:00Z"), newestDate: null, error: null }, false),
    "마지막 불러옴: 2026-11-16 12:00 · 데이터: 없음까지");
  assert.equal(line({ lastRunMs: null, newestDate: null, error: "429 rate_limit_error: slow" }, true),
    "아직 불러오지 못했습니다 · 오류: 429 rate_limit_error: slow");
  assert.equal(line({ lastRunMs: 1, newestDate: "2026-11-15", error: "x" }, false).startsWith("마지막 불러옴: "), true);
  assert.ok(line({ lastRunMs: 1, newestDate: "2026-11-15", error: "x" }, false).endsWith(" · 오류: x"));
});

function render(e, kind, startRow) {
  const sheet = S.fakes.ss.insertSheet("t" + Math.random());
  const model = S.computeEnterpriseSection(e, kind || "thisMonth", TODAY);
  const last = S.renderEnterpriseSection(sheet, startRow || 30, model, e, TZ);
  return { sheet, last, model };
}
function cell(sheet, row, col) { return (sheet._rows[row - 1] || [])[col - 1]; }

test("renderEnterpriseSection: rows and values at the documented offsets", () => {
  const e = MANY;
  const { sheet, last } = render(e, "thisMonth", 30);
  const s = 30;
  assert.equal(cell(sheet, s, 1), "Enterprise 멤버 (Claude 관리자 통계)");
  assert.equal(cell(sheet, s + 1, 1), "아직 불러오지 못했습니다");
  assert.deepEqual(sheet._rows[s + 2].slice(0, 4), ["메시지", "1인 평균", "쓰는 사람", "부서 수"]);
  assert.deepEqual(sheet._rows[s + 3].slice(0, 4), [83, 83 / 8, 8, 3]);
  assert.deepEqual(sheet._rows[s + 4].slice(0, 4), ["+730.0%", "+3.8%", "+7명", ""]);
  assert.deepEqual(sheet._rows[s + 6].slice(0, 4), ["부서", "메시지", "1인 평균", "인원"]);
  assert.deepEqual(sheet._rows[s + 7].slice(0, 4), ["교육", 40, 20, 2]);
  assert.deepEqual(sheet._rows[s + 6].slice(5, 9), ["많이 쓰는 사람", "부서", "메시지", "Claude Code 세션"]);
  assert.deepEqual(sheet._rows[s + 7].slice(5, 9), ["d", "교육", 40, 4]);
  assert.deepEqual(sheet._rows[s + 14].slice(5, 9), ["적게 쓰는 사람", "부서", "메시지", "Claude Code 세션"]);
  assert.deepEqual(sheet._rows[s + 15].slice(5, 9), ["cy", "교육", 0, 0]);
  // unassigned line two rows below the bottom table (its 3 rows end at s+17), notes two rows below that
  const unassignedRow = s + 20 + 2;
  assert.equal(cell(sheet, unassignedRow, 1), "미지정: 1명 · 100 메시지 — 엔터프라이즈 사람 탭에 부서를 적으면 포함됩니다");
  const notes = [
    "Enterprise 조직 멤버만, Anthropic 관리자 통계 기준입니다. 하루 늦게(보통 다음 날 밤 10시쯤) 채워집니다.",
    "날짜는 UTC 하루 기준이라 한국 날짜와 9시간 어긋납니다.",
    "메시지 = 채팅 + Cowork 메시지. Claude Code 사용은 세션 수로 따로 셉니다.",
    "부서는 엔터프라이즈 사람 탭에서 정합니다. 비어 있으면 미지정입니다.",
    "관리자 통계에 안 나온 사람은 보이지 않습니다.",
  ];
  notes.forEach((n, i) => assert.equal(cell(sheet, unassignedRow + 2 + i, 1), n));
  assert.equal(last, unassignedRow + 2 + 4);
  assert.equal(sheet._widths[9], 110);
  assert.ok(sheet.getMaxRows() >= last);
});

test("renderEnterpriseSection: the chart is a titled BAR at (s+3, 10) with one header row", () => {
  const { sheet } = render(MANY, "thisMonth", 30);
  const charts = sheet.getCharts();
  assert.equal(charts.length, 1);
  const c = charts[0];
  assert.equal(c.chartType, "BAR");
  assert.equal(c.options.title, "부서별 메시지 (Enterprise)");
  assert.deepEqual(plain(c.position), { row: 33, col: 10, offsetX: 0, offsetY: 0 });
  assert.equal(c.numHeaders, 1);
  assert.deepEqual(plain(c.ranges), [{ row: 37, col: 1, numRows: 4, numCols: 1 }, { row: 37, col: 2, numRows: 4, numCols: 1 }]);
  assert.equal(c.options.width, 480);
  assert.equal(c.options.height, 300);
  assert.deepEqual(plain(c.options.legend), { position: "none" });
});

test("renderEnterpriseSection: no data writes only the title and status rows", () => {
  const { sheet, last } = render(ent([], {}, { hasKey: false }), "thisMonth", 30);
  assert.equal(last, 31);
  assert.equal(cell(sheet, 30, 1), "Enterprise 멤버 (Claude 관리자 통계)");
  assert.equal(cell(sheet, 31, 1), "Enterprise 키가 없습니다 — 메뉴 > Enterprise API 키 넣기");
  assert.equal(sheet.getLastRow(), 31);
  assert.equal(sheet.getCharts().length, 0);
});

test("renderEnterpriseSection: no chart without departments, and API-derived text is written as text", () => {
  const e = ent([use("2026-11-02", "u", "=HYPERLINK(1)@x.com", 3, 0)], { u: { email: "=HYPERLINK(1)@x.com", dept: "" } },
    { status: { lastRunMs: null, newestDate: null, error: "=1+1" } });
  const { sheet } = render(e, "thisMonth", 10);
  assert.equal(sheet.getCharts().length, 0);
  assert.equal(cell(sheet, 11, 1), "아직 불러오지 못했습니다 · 오류: =1+1");
  assert.ok(!(typeof cell(sheet, 11, 1) === "object"), "the status line is text, not a formula");
});

test("refreshAll: a pull that throws on every fetch still renders everything and records the error", () => {
  const S2 = loadScript();
  S2.fakes.props.user.enterprise_api_key = KEY;
  S2.fakes.http.handler = () => { throw new Error("boom"); };
  S2.refreshAll();
  const status = JSON.parse(S2.fakes.props.doc.enterprise_status);
  assert.match(status.error, /^요청 실패/);
  ["이번 달", "지난 7일", "지난달"].forEach((name) => {
    const sh = S2.fakes.ss.getSheetByName(name);
    assert.equal(plain(sh._rows.flat()).includes("Enterprise 멤버 (Claude 관리자 통계)"), true, name);
  });
  assert.ok(S2.fakes.ss.getSheetByName("플랜").getLastRow() > 0);
  assert.equal(S2.fakes.lockStats.docHeld, false);
  assert.equal(S2.fakes.lockStats.held, false);
  assert.equal(S2.fakes.lockStats.released, S2.fakes.lockStats.acquired);
});

test("refreshAll: an unexpected throw from pullEnterprise never stops the dashboards", () => {
  const S2 = loadScript();
  S2.pullEnterprise = () => { throw new Error("unexpected"); };
  S2.refreshAll();
  assert.ok(S2.fakes.ss.getSheetByName("이번 달").getLastRow() > 0);
  assert.equal(S2.fakes.lockStats.docHeld, false);
});

test("refreshAll without a key shows the owner's last pull and sends no request (Review Focus 4)", () => {
  const S2 = loadScript();
  S2.fakes.http.handler = () => { throw new Error("must not be called"); };
  S2.fakes.props.doc.enterprise_status = JSON.stringify({ lastRunMs: Date.parse("2026-11-16T01:00:00Z"), newestDate: "2026-11-15", error: null });
  S2.refreshAll();
  assert.equal(S2.fakes.http.requests.length, 0);
  const rows = S2.fakes.ss.getSheetByName("이번 달")._rows.flat();
  assert.ok(rows.includes("마지막 불러옴: 2026-11-16 10:00 · 데이터: 2026-11-15까지"));
  assert.ok(!rows.includes("Enterprise 키가 없습니다 — 메뉴 > Enterprise API 키 넣기"));
});

test("refreshAll without any key or status says the key is missing", () => {
  const S2 = loadScript();
  S2.refreshAll();
  assert.ok(S2.fakes.ss.getSheetByName("이번 달")._rows.flat().includes("Enterprise 키가 없습니다 — 메뉴 > Enterprise API 키 넣기"));
});

test("setEnterpriseKey: OK stores the trimmed key, refreshes with requests and shows one alert", () => {
  const S2 = loadScript();
  S2.fakes.http.handler = () => ({ code: 400, body: { error: { type: "invalid_request_error", message: "not yet" } } });
  S2.fakes.ui.next = { button: "OK", text: "  k-123  " };
  S2.setEnterpriseKey();
  assert.equal(S2.fakes.props.user.enterprise_api_key, "k-123");
  assert.ok(S2.fakes.http.requests.length > 0);
  assert.equal(S2.fakes.http.requests[0].opts.headers["x-api-key"], "k-123");
  assert.equal(S2.fakes.ui.alerts.length, 1);
  assert.ok(!S2.fakes.ui.alerts[0].includes("k-123"));
});

test("setEnterpriseKey: CANCEL and empty text store nothing", () => {
  const S2 = loadScript();
  S2.fakes.http.handler = () => { throw new Error("no requests expected"); };
  S2.fakes.ui.next = { button: "CANCEL", text: "k-123" };
  S2.setEnterpriseKey();
  S2.fakes.ui.next = { button: "OK", text: "   " };
  S2.setEnterpriseKey();
  assert.equal("enterprise_api_key" in S2.fakes.props.user, false);
  assert.equal(S2.fakes.http.requests.length, 0);
  assert.equal(S2.fakes.ui.alerts.length, 0);
});

test("clearEnterpriseKey deletes the key and shows one alert", () => {
  const S2 = loadScript();
  S2.fakes.props.user.enterprise_api_key = KEY;
  S2.clearEnterpriseKey();
  assert.equal("enterprise_api_key" in S2.fakes.props.user, false);
  assert.equal(S2.fakes.ui.alerts.length, 1);
});
