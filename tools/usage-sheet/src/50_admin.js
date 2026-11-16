// Owner-facing entry points: setup, the hourly refresh, the menu, and sample data.

var SAMPLE_MEMBER_PREFIX = "00000000-0000-4000-8000-";
var SAMPLE_TEAM_PREFIX = "t_sample_";
var SAMPLE_ACCOUNT_PREFIX = "sample_";

// Which columns (1-based) carry sample keys in each data tab.
var SAMPLE_KEYS = [
  { tab: TAB_RAW, cols: COLS_RAW, keys: [[1, SAMPLE_MEMBER_PREFIX], [5, SAMPLE_TEAM_PREFIX]] },
  { tab: TAB_LIMITS, cols: COLS_LIMITS, keys: [[1, SAMPLE_ACCOUNT_PREFIX], [4, SAMPLE_MEMBER_PREFIX], [5, SAMPLE_TEAM_PREFIX]] },
  { tab: TAB_PEOPLE, cols: COLS_PEOPLE, keys: [[1, SAMPLE_MEMBER_PREFIX]] },
  { tab: TAB_DEPTS, cols: COLS_DEPTS, keys: [[1, SAMPLE_TEAM_PREFIX]] },
  { tab: TAB_TEAMLABELS, cols: COLS_TEAMLABELS, keys: [[1, SAMPLE_TEAM_PREFIX], [2, SAMPLE_MEMBER_PREFIX]] },
  { tab: TAB_DEVICES, cols: COLS_DEVICES, keys: [[1, SAMPLE_MEMBER_PREFIX]] }
];

function withScriptLock(fn) {
  var lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    return fn();
  } finally {
    lock.releaseLock();
  }
}

// The 7 data tabs plus the 3 dashboards and the plan tab; existing tabs are left alone.
function ensureAllTabs(ss) {
  ensureSheets(ss);
  DASHBOARD_TABS.map(function (d) { return d.name; }).concat([TAB_PLAN]).forEach(function (name) {
    if (!ss.getSheetByName(name)) ss.insertSheet(name);
  });
}

// For each team, the most common non-empty label; ties go to the label that sorts first.
function suggestedTeamNames(teamLabels) {
  var counts = new Map();
  teamLabels.forEach(function (t) {
    var label = String(t.label).trim();
    if (!label) return;
    if (!counts.has(t.team)) counts.set(t.team, new Map());
    var m = counts.get(t.team);
    m.set(label, (m.get(label) || 0) + 1);
  });
  var out = new Map();
  counts.forEach(function (m, team) {
    var best = null, bestCount = 0;
    m.forEach(function (n, label) {
      if (n > bestCount || (n === bestCount && label < best)) { best = label; bestCount = n; }
    });
    out.set(team, best);
  });
  return out;
}

// Call inside the script lock: it re-reads 부서 so a row a report just added is kept, and it writes
// column C only, so the owner's 부서이름 is never touched.
function writeSuggestedTeamNames(ss, data) {
  var sheet = ss.getSheetByName(TAB_DEPTS);
  var rows = sheetRows(sheet, COLS_DEPTS.length);
  if (!rows.length) return;
  var names = suggestedTeamNames(data.teamLabels);
  var column = rows.map(function (r) { return [names.has(r[0]) ? names.get(r[0]) : r[2]]; });
  sheet.getRange(2, 3, rows.length, 1).setValues(asTextRows(column));
}

// Reading and rendering run without the script lock, so a slow refresh never makes a report wait: only
// the dashboards and the plan are written, and nobody else writes them. The lock is taken for the tab
// creation and for the 참고팀이름 write.
function refreshAll() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var tz = Session.getScriptTimeZone();
  var nowMs = Date.now();
  var today = localDateString(nowMs, tz);
  withScriptLock(function () { ensureAllTabs(ss); });
  var data = readAll(ss, tz);
  withScriptLock(function () { writeSuggestedTeamNames(ss, data); });
  DASHBOARD_TABS.forEach(function (d) {
    renderDashboard(ss.getSheetByName(d.name), computeDashboard(data, d.kind, today), nowMs, tz);
  });
  renderPlan(ss.getSheetByName(TAB_PLAN), computePlan(data, nowMs, tz), nowMs, tz);
}

// Deletes the untouched default tab, puts the dashboards and the plan first (data tabs after them) and
// opens 이번 달. Hidden tabs are left where they are.
function arrangeTabs(ss) {
  var ours = new Set(TAB_SPECS.map(function (t) { return t.name; }));
  DASHBOARD_TABS.forEach(function (d) { ours.add(d.name); });
  ours.add(TAB_PLAN);
  ss.getSheets().forEach(function (sh) {
    if (!ours.has(sh.getName()) && sh.getLastRow() === 0 && ss.getSheets().length > 1 &&
        (sh.getName() === "시트1" || sh.getName() === "Sheet1")) ss.deleteSheet(sh);
  });
  var order = DASHBOARD_TABS.map(function (d) { return d.name; }).concat([TAB_PLAN],
    TAB_SPECS.map(function (t) { return t.name; }).filter(function (n) { return !ss.getSheetByName(n).isSheetHidden(); }));
  order.forEach(function (name, i) {
    ss.setActiveSheet(ss.getSheetByName(name));
    ss.moveActiveSheet(i + 1);
  });
  ss.setActiveSheet(ss.getSheetByName(DASHBOARD_TABS[0].name));
}

function setup() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  withScriptLock(function () { ensureAllTabs(ss); });
  arrangeTabs(ss);
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === "refreshAll") ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger("refreshAll").timeBased().everyHours(1).create();
  refreshAll();
}

function onOpen(e) {
  SpreadsheetApp.getUi().createMenu("사용량 대시보드")
    .addItem("지금 새로 고침", "refreshAll")
    .addItem("샘플 데이터 넣기", "seedSampleData")
    .addItem("샘플 데이터 지우기", "clearSampleData")
    .addToUi();
}

function isSampleRow(spec, row) {
  return spec.keys.some(function (k) {
    var v = row[k[0] - 1];
    return typeof v === "string" && v.indexOf(k[1]) === 0;
  });
}

// Reads each tab, drops the sample rows and writes the rest back. Real rows keep their order.
function removeSampleRows(ss) {
  SAMPLE_KEYS.forEach(function (spec) {
    var sheet = ss.getSheetByName(spec.tab);
    if (!sheet) return;
    var width = spec.cols.length;
    var rows = sheetRows(sheet, width);
    var kept = rows.filter(function (r) { return !isSampleRow(spec, r); });
    if (kept.length === rows.length) return;
    // Kept rows first, then only the leftover tail is cleared: the body is never empty in between.
    if (kept.length) sheet.getRange(2, 1, kept.length, width).setValues(asTextRows(kept));
    sheet.getRange(kept.length + 2, 1, rows.length - kept.length, width).clearContent();
  });
}

function appendRows(sheet, width, rows) {
  if (!rows.length) return;
  var start = Math.max(sheet.getLastRow(), 1) + 1;
  ensureRows(sheet, start + rows.length - 1);
  sheet.getRange(start, 1, rows.length, width).setValues(asTextRows(rows));
}

function sampleMemberId(i) {
  return SAMPLE_MEMBER_PREFIX + ("000000000000" + (i + 1).toString(16)).slice(-12);
}

var SAMPLE_DEPTS = [
  { team: "t_sample_dev", name: "개발팀", label: "개발", people: ["해달", "지아", "모카"] },
  { team: "t_sample_edu", name: "교육운영팀", label: "교육", people: ["서연", "도윤", "하늘"] },
  { team: "t_sample_design", name: "디자인팀", label: "디자인", people: ["보리", "나래", "다온"] },
  { team: "t_sample_biz", name: "사업팀", label: "사업", people: ["이든", "채원", "별이"] }
];

function seedSampleData() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var tz = Session.getScriptTimeZone();
  var nowMs = Date.now();
  var today = localDateString(nowMs, tz);
  var firstDay = dateToDayNumber(periodRange("lastMonth", today).start);
  var todayNum = dateToDayNumber(today);
  var nowIso = msToIso(nowMs);
  var hourMs = 3600000;
  var weekMs = 7 * 24 * hourMs;

  withScriptLock(function () {
    ensureAllTabs(ss);
    removeSampleRows(ss);
    var raw = [], limits = [], people = [], depts = [], labels = [], devices = [];
    var idx = 0;
    SAMPLE_DEPTS.forEach(function (dept) {
      depts.push([dept.team, dept.name, dept.label, today]);
      dept.people.forEach(function (nick, pi) {
        var id = sampleMemberId(idx);
        var n = idx;
        people.push([id, nick, nowIso, "", "2.5.0", n % 3 === 2 ? "windows" : "mac"]);
        devices.push([id, sha256Hex("sample-secret-" + n), nowIso, nowIso]);
        if (pi === 0) labels.push([dept.team, id, dept.label, nowIso]);
        var level = 1 + ((n * 7) % 5);   // 1..5: a spread of heavy and light users
        for (var d = firstDay; d <= todayNum; d++) {
          if ((n + d) % 7 === 0) continue;   // some days off
          var date = dayNumberToString(d);
          var base = level * 1500000 + ((d * 31 + n * 17) % 9) * 400000;
          [["claude_code", base], ["codex", Math.round(base / 3)]].forEach(function (t) {
            var total = t[1];
            var input = Math.round(total * 0.05), output = Math.round(total * 0.03), cw = Math.round(total * 0.12);
            raw.push([id, nick, date, t[0], dept.team, input, output, cw, total - input - output - cw, total,
              "2.5.0", "mac", nowIso]);
          });
        }
        // 5 weekly windows per account: the current one resets 1-5 days ahead, the older four are finished.
        [["claude", "sample_c" + n, n % 2 ? "Max" : "Pro"], ["codex", "sample_x" + n, "plus"]].forEach(function (a, ai) {
          if (ai === 1 && n % 3 !== 0) return;
          var reset = Math.ceil((nowMs + (1 + n % 5) * 24 * hourMs) / hourMs) * hourMs;
          for (var w = 0; w < 5; w++) {
            var resetsAt = reset - w * weekMs;
            var used = w === 0 ? 15 + ((n * 13) % 70) : Math.min(100, 30 + ((n * 11 + w * 23) % 71));
            var readAt = w === 0 ? nowMs - hourMs : resetsAt - hourMs;
            limits.push([a[1], a[0], msToIso(resetsAt), id, dept.team, a[2], "sample.example",
              used, used, msToIso(readAt)]);
          }
        });
        idx++;
      });
    });
    appendRows(ss.getSheetByName(TAB_RAW), COLS_RAW.length, raw);
    appendRows(ss.getSheetByName(TAB_LIMITS), COLS_LIMITS.length, limits);
    appendRows(ss.getSheetByName(TAB_PEOPLE), COLS_PEOPLE.length, people);
    appendRows(ss.getSheetByName(TAB_DEPTS), COLS_DEPTS.length, depts);
    appendRows(ss.getSheetByName(TAB_TEAMLABELS), COLS_TEAMLABELS.length, labels);
    appendRows(ss.getSheetByName(TAB_DEVICES), COLS_DEVICES.length, devices);
  });
  refreshAll();
}

function clearSampleData() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  withScriptLock(function () { removeSampleRows(ss); });
  refreshAll();
}
