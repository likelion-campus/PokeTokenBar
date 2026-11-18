"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { loadScript } = require("./harness.js");

const TZ = "Asia/Seoul";
const KEY = "sk-ant-secret-KEY-123";
const fixtureDir = path.join(__dirname, "..", "fixtures", "enterprise");
function fixture(name) { return JSON.parse(fs.readFileSync(path.join(fixtureDir, name), "utf8")); }
// Values built inside the vm context have foreign prototypes; compare through JSON.
function plain(v) { return JSON.parse(JSON.stringify(v)); }

// 2026-01-05 03:00Z: window 01-01..01-04 (yesterday UTC = 01-04, recent window 01-02..01-04).
const NOW_SMALL = Date.parse("2026-01-05T03:00:00Z");
// 2026-11-30 03:00Z: window 2026-09-01..11-29 = 90 days.
const NOW_LONG = Date.parse("2026-11-30T03:00:00Z");
// 2026-11-16 03:00Z: window 2026-09-01..11-15 = 76 days.
const NOW_MID = Date.parse("2026-11-16T03:00:00Z");

function load(nowMs, handler, withKey) {
  const S = loadScript({ nowMs });
  if (withKey !== false) S.fakes.props.user.enterprise_api_key = KEY;
  S.fakes.http.handler = handler;
  return S;
}
function ok(records, next) { return { code: 200, body: { data: records, next_page: next === undefined ? null : next } }; }
function rec(id, email, chat, conv) {
  return {
    user: { id, email_address: email, type: "user" },
    chat_metrics: { message_count: chat, distinct_conversation_count: conv },
    cowork_metrics: { message_count: 1 },
    claude_code_metrics: { core_metrics: { distinct_session_count: 2 } }
  };
}
function dateOf(url) { return /date=(\d{4}-\d{2}-\d{2})/.exec(url)[1]; }
function pull(S) { return plain(S.pullEnterprise(S.fakes.ss, S.nowMs, TZ)); }
function status(S) { return JSON.parse(S.fakes.props.doc.enterprise_status); }
function dataRows(S, tab) { return S.fakes.ss.getSheetByName(tab)._rows.slice(1).map(plain); }
function logDates(S) { return dataRows(S, "엔터프라이즈기록").map((r) => r[0]); }
function dayPlus(base, n) { return new Date(Date.parse(base + "T00:00:00Z") + n * 86400000).toISOString().slice(0, 10); }

test("entRecordToRow sums chat and unified chat, cowork and unified sessions", () => {
  const S = loadScript();
  const p1 = fixture("users-page1.json");
  assert.deepEqual(plain(S.entRecordToRow(p1.data[0], "2026-11-14", "NOW")),
    ["2026-11-14", "user_ada", "ada@example.com", 10, 3, 4, 2, "NOW"]);
  // bo moved to Chat and Cowork unified: 5+7 messages, 2+1 conversations, 0+6 cowork messages.
  assert.deepEqual(plain(S.entRecordToRow(p1.data[1], "2026-11-14", "NOW")),
    ["2026-11-14", "user_bo", "bo@example.com", 12, 3, 6, 1, "NOW"]);
});

test("entRecordToRow treats missing objects and null counts as 0 and drops user-less records", () => {
  const S = loadScript();
  const row = plain(S.entRecordToRow({ user: { id: "u1" }, chat_metrics: { message_count: 4, distinct_conversation_count: null }, chat_cowork_unified_metrics: null }, "d", "n"));
  assert.deepEqual(row, ["d", "u1", "", 4, 0, 0, 0, "n"]);
  assert.equal(S.entRecordToRow({ user: null, chat_metrics: { message_count: 1 } }, "d", "n"), null);
  assert.equal(S.entRecordToRow({ user: { email_address: "x@y" } }, "d", "n"), null);
});

test("entDaysToFetch includes gaps and the recent days, ascending without duplicates", () => {
  const S = loadScript();
  const fetched = new Set(["2026-01-01", "2026-01-03", "2026-01-04", "2026-01-05", "2026-01-06", "2026-01-07"]);
  assert.deepEqual(plain(S.entDaysToFetch(fetched, "2026-01-01", "2026-01-07", 3)),
    ["2026-01-02", "2026-01-05", "2026-01-06", "2026-01-07"]);
  assert.deepEqual(plain(S.entDaysToFetch(new Set(), "2026-01-01", "2026-01-02", 3)), ["2026-01-01", "2026-01-02"]);
  assert.deepEqual(plain(S.entDaysToFetch(new Set(), "2026-01-05", "2026-01-04", 3)), []);
});

test("pagination follows next_page with the pinned headers", () => {
  const p1 = fixture("users-page1.json"), p2 = fixture("users-page2.json");
  const S = load(Date.parse("2026-01-03T03:00:00Z"), (url) => ({ code: 200, body: url.includes("&page=") ? p2 : p1 }));
  const r = pull(S);
  assert.deepEqual(r, { saved: 2, error: null });
  const reqs = S.fakes.http.requests;
  assert.equal(reqs.length, 4);
  assert.equal(reqs[0].url, "https://api.anthropic.com/v1/organizations/analytics/users?date=2026-01-01&limit=1000");
  assert.equal(reqs[1].url, "https://api.anthropic.com/v1/organizations/analytics/users?date=2026-01-01&limit=1000&page=cursor%2Fabc%3D%3D");
  reqs.forEach((q) => {
    assert.deepEqual(plain(q.opts), { method: "get", headers: { "x-api-key": KEY, "anthropic-version": "2026-10-21" }, muteHttpExceptions: true });
  });
  assert.equal(dataRows(S, "엔터프라이즈 원본").length, 6);
  assert.deepEqual(dataRows(S, "엔터프라이즈기록").map((r) => [r[0], r[2]]), [["2026-01-01", 3], ["2026-01-02", 3]]);
});

test("no key skips the pull: no request and the status is untouched", () => {
  const S = load(NOW_SMALL, () => ok([]), false);
  assert.deepEqual(pull(S), { skipped: true });
  assert.equal(S.fakes.http.requests.length, 0);
  assert.deepEqual(Object.keys(S.fakes.props.doc), []);
});

test("a 400 on yesterday is normal: no error, the run ends there, earlier days are saved", () => {
  const S = load(NOW_SMALL, (url) => dateOf(url) === "2026-01-04"
    ? { code: 400, body: { type: "error", error: { type: "invalid_request_error", message: "not yet" } } }
    : ok([rec("u1", "a@x.com", 1, 1)]));
  assert.deepEqual(pull(S), { saved: 3, error: null });
  assert.deepEqual(logDates(S), ["2026-01-01", "2026-01-02", "2026-01-03"]);
  const st = status(S);
  assert.equal(st.error, null);
  assert.equal(st.lastRunMs, NOW_SMALL);
  assert.equal(st.newestDate, "2026-01-03");
});

test("a 400 on a day older than the recent window is an error", () => {
  const S = load(NOW_SMALL, (url) => dateOf(url) === "2026-01-01"
    ? { code: 400, body: { type: "error", error: { type: "invalid_request_error", message: "bad date" } } }
    : ok([]));
  const r = pull(S);
  assert.equal(r.error, "400 invalid_request_error: bad date");
  assert.equal(status(S).error, "400 invalid_request_error: bad date");
  assert.equal(status(S).lastRunMs, null);
});

test("a 401 sets the error and nothing is written for later days", () => {
  const S = load(NOW_SMALL, (url) => dateOf(url) === "2026-01-02"
    ? { code: 401, body: { type: "error", error: { type: "authentication_error", message: "invalid x-api-key" } } }
    : ok([rec("u1", "a@x.com", 1, 1)]));
  const r = pull(S);
  assert.equal(r.error, "401 authentication_error: invalid x-api-key");
  assert.deepEqual(logDates(S), ["2026-01-01"]);
  assert.equal(S.fakes.http.requests.length, 2);
});

test("an HTTP failure whose body is not the error shape reads \"<code> 응답\"", () => {
  const S = load(NOW_SMALL, () => ({ code: 503, body: "<html>down</html>" }));
  assert.equal(pull(S).error, "503 응답");
});

test("an error text is cut to 200 characters", () => {
  const S = load(NOW_SMALL, () => ({ code: 401, body: { error: { type: "authentication_error", message: "x".repeat(500) } } }));
  pull(S);
  assert.equal(status(S).error.length, 200);
});

test("a 429 after 40 days keeps them and the next run resumes at day 41", () => {
  const first = "2026-09-01";
  let limited = true;
  const S = load(NOW_LONG, (url) => {
    const idx = (Date.parse(dateOf(url)) - Date.parse(first)) / 86400000;
    if (limited && idx >= 40) return { code: 429, body: { type: "error", error: { type: "rate_limit_error", message: "slow down" } } };
    return ok([rec("u1", "a@x.com", 1, 1)]);
  });
  const r1 = pull(S);
  assert.equal(r1.saved, 40);
  assert.ok(r1.error.startsWith("429"));
  assert.equal(logDates(S).length, 40);
  const n1 = S.fakes.http.requests.length;
  assert.equal(n1, 41);
  assert.equal(S.fakes.sleeps.length, n1 - 1);
  assert.equal(status(S).lastRunMs, null);

  limited = false;
  S.fakes.http.requests.length = 0;
  const r2 = pull(S);
  assert.equal(r2.error, null);
  const firstDay2 = dateOf(S.fakes.http.requests[0].url);
  assert.equal(firstDay2, dayPlus(first, 40));
  S.fakes.http.requests.forEach((q) => assert.ok(dateOf(q.url) >= dayPlus(first, 40)));
  assert.equal(logDates(S).length, 90);
});

test("the request budget is reached through pagination: 100 requests, no error", () => {
  const S = load(NOW_MID, (url) => url.includes("&page=")
    ? ok([rec("u2", "b@x.com", 1, 1)])
    : ok([rec("u1", "a@x.com", 1, 1)], "next"));
  const r = pull(S);
  assert.equal(S.fakes.http.requests.length, 100);
  assert.equal(S.fakes.sleeps.length, 99);
  assert.deepEqual(r, { saved: 50, error: null });
  assert.equal(logDates(S).length, 50);
  assert.equal(status(S).error, null);
});

test("re-fetching a day leaves one row per date and user, with the latest values", () => {
  let chat = 5;
  const S = load(Date.parse("2026-01-02T03:00:00Z"), () => ok([rec("u1", "a@x.com", chat, 1), rec("u2", "b@x.com", 1, 1)]));
  pull(S);
  chat = 9;
  pull(S);
  const rows = dataRows(S, "엔터프라이즈 원본");
  assert.equal(rows.length, 2);
  assert.equal(rows.find((r) => r[1] === "u1")[3], 9);
  assert.equal(dataRows(S, "엔터프라이즈기록").length, 1);
});

test("a typed 부서 survives the next pull while the email is updated", () => {
  let email = "old@x.com";
  const S = load(Date.parse("2026-01-02T03:00:00Z"), () => ok([rec("u1", email, 1, 1)]));
  pull(S);
  const people = S.fakes.ss.getSheetByName("엔터프라이즈 사람");
  assert.deepEqual(plain(people._rows[1]).slice(0, 3), ["u1", "old@x.com", ""]);
  people._rows[1][2] = "개발팀";
  email = "new@x.com";
  pull(S);
  assert.deepEqual(plain(people._rows[1]).slice(0, 3), ["u1", "new@x.com", "개발팀"]);
  assert.equal(people._rows.length, 2);
});

test("a thrown fetch becomes the error and the days collected before it are written", () => {
  const S = load(NOW_SMALL, (url) => {
    if (dateOf(url) === "2026-01-03") throw new Error("DNS error");
    return ok([rec("u1", "a@x.com", 1, 1)]);
  });
  const r = pull(S);
  assert.equal(r.error, "요청 실패: DNS error");
  assert.equal(r.saved, 2);
  assert.deepEqual(logDates(S), ["2026-01-01", "2026-01-02"]);
});

test("an unparseable 200 is an error", () => {
  const S = load(NOW_SMALL, () => ({ code: 200, body: "not json" }));
  assert.equal(pull(S).error, "응답을 읽지 못했습니다");
});

test("the key appears in no cell, no stored status and no request URL", () => {
  const scenarios = [
    () => ok([rec("u1", "a@x.com", 1, 1)]),
    () => ({ code: 400, body: { error: { type: "invalid_request_error", message: "bad" } } }),
    () => ({ code: 401, body: { error: { type: "authentication_error", message: "invalid" } } }),
    () => { throw new Error("network down"); },
    () => ({ code: 200, body: "not json" })
  ];
  scenarios.forEach((handler) => {
    const S = load(NOW_SMALL, handler);
    pull(S);
    const cells = JSON.stringify(S.fakes.ss.getSheets().map((s) => s._rows));
    assert.ok(!cells.includes(KEY));
    assert.ok(!JSON.stringify(S.fakes.props.doc).includes(KEY));
    S.fakes.http.requests.forEach((q) => assert.ok(!q.url.includes(KEY)));
  });
});

test("an email that starts with = is stored as text, not a formula", () => {
  const S = load(Date.parse("2026-01-02T03:00:00Z"), () => ok([rec("u1", "=HYPERLINK(\"x\")", 1, 1)]));
  pull(S);
  [["엔터프라이즈 원본", 2], ["엔터프라이즈 사람", 1]].forEach(([tab, col]) => {
    const v = S.fakes.ss.getSheetByName(tab)._rows[1][col];
    assert.equal(typeof v, "string");
    assert.equal(v, "=HYPERLINK(\"x\")");
  });
});

test("readEnterprise returns typed numbers, a trimmed 부서, the status and hasKey", () => {
  const S = load(Date.parse("2026-01-02T03:00:00Z"), () => ok([rec("u1", "a@x.com", 5, 2)]));
  pull(S);
  S.fakes.ss.getSheetByName("엔터프라이즈 사람")._rows[1][2] = "  개발팀 ";
  const e = plain(S.readEnterprise(S.fakes.ss, TZ));
  assert.deepEqual(e.usage, [{ date: "2026-01-01", userId: "u1", email: "a@x.com", chat: 5, conv: 2, cowork: 1, code: 2 }]);
  assert.deepEqual(e.people, { u1: { email: "a@x.com", dept: "개발팀" } });
  assert.equal(e.status.error, null);
  assert.equal(e.hasKey, true);
  delete S.fakes.props.user.enterprise_api_key;
  assert.equal(S.readEnterprise(S.fakes.ss, TZ).hasKey, false);
});

test("the newest collected day's email wins and the 부서 is untouched", () => {
  const S = load(Date.parse("2026-01-03T03:00:00Z"), (url) =>
    ok([rec("u1", dateOf(url) === "2026-01-01" ? "old@x.com" : "new@x.com", 1, 1)]));
  pull(S);
  const people = S.fakes.ss.getSheetByName("엔터프라이즈 사람");
  assert.equal(people._rows.length, 2);
  assert.deepEqual(plain(people._rows[1]).slice(0, 3), ["u1", "new@x.com", ""]);
  assert.equal(plain(people._rows[1])[3], "2026-01-03");
});

test("no lock is held while a request is sent; the script lock is taken once for the writes", () => {
  const S = load(NOW_SMALL, (url) => {
    assert.equal(S.fakes.lockStats.held, false);
    return ok([rec("u1", "a@x.com", 1, 1)]);
  });
  pull(S);
  assert.ok(S.fakes.http.requests.length > 1);
  assert.equal(S.fakes.lockStats.acquired, 1);
  assert.equal(S.fakes.lockStats.released, 1);
});

test("the pull stops on the time budget: collected days are written, no error, the next run resumes", () => {
  // NOW_LONG window: 2026-09-01..11-29 = 90 days. Each request costs 3 s of simulated time.
  const first = "2026-09-01";
  let S;
  S = load(NOW_LONG, () => { S.fakes.clock.advance(3000); return ok([rec("u1", "a@x.com", 1, 1)]); });
  const t0 = S.fakes.clock.offset;
  const r1 = pull(S);
  const used = S.fakes.clock.offset - t0;
  assert.equal(r1.error, null);
  assert.ok(used < 150000 + 3000, "stopped near 150 s, got " + used);
  assert.equal(S.fakes.http.requests.length, 50);
  assert.equal(r1.saved, 50);
  assert.equal(logDates(S).length, 50);
  assert.equal(status(S).error, null);
  S.fakes.http.requests.length = 0;
  pull(S);
  assert.equal(dateOf(S.fakes.http.requests[0].url), dayPlus(first, 50));
  assert.equal(logDates(S).length, 90);
});

test("a single slow multi-page day also stops on the time budget", () => {
  let S;
  S = load(NOW_SMALL, (url) => {
    S.fakes.clock.advance(80000);
    return url.includes("&page=") ? ok([rec("u2", "b@x.com", 1, 1)], "more") : ok([rec("u1", "a@x.com", 1, 1)], "more");
  });
  const r = pull(S);
  assert.equal(r.error, null);
  assert.equal(S.fakes.http.requests.length, 2);
  assert.equal(r.saved, 0);
});

test("a thrown fetch error never carries the request address into the status", () => {
  const S = load(NOW_SMALL, () => {
    throw new Error("Address unavailable: https://api.anthropic.com/v1/organizations/analytics/users?date=2026-11-01&limit=1000");
  });
  const r = pull(S);
  assert.ok(r.error.startsWith("요청 실패: Address unavailable: "));
  assert.ok(!r.error.includes("https://"));
  assert.ok(!status(S).error.includes("https://"));
  assert.ok(!status(S).error.includes("api.anthropic.com"));
});

test("a re-fetch that changes nothing rewrites no 엔터프라이즈 원본 row; a changed value is rewritten", () => {
  let chat = 5;
  const S = load(Date.parse("2026-01-04T03:00:00Z"), () => ok([rec("u1", "a@x.com", chat, 1), rec("u2", "b@x.com", 2, 1)]));
  pull(S);
  const raw = S.fakes.ss.getSheetByName("엔터프라이즈 원본");
  const writes = () => raw._ops.filter((o) => o[0] === "set").length;
  assert.equal(raw._rows.length, 1 + 3 * 2);
  const stamp = plain(raw._rows[1]);
  // Later pull: new 받은시각 but identical values in columns 1-7.
  S.nowMs += 3600000;
  S.fakes.clock.advance(3600000);
  const before = writes();
  plain(S.pullEnterprise(S.fakes.ss, S.nowMs, TZ));
  assert.equal(writes() - before, 0);
  assert.deepEqual(plain(raw._rows[1]), stamp);
  chat = 9;
  S.nowMs += 3600000;
  const before2 = writes();
  plain(S.pullEnterprise(S.fakes.ss, S.nowMs, TZ));
  assert.ok(writes() - before2 > 0);
  assert.equal(raw._rows.filter((r) => r[1] === "u1").every((r) => r[3] === 9), true);
});
