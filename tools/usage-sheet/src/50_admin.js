// Owner-facing entry points: setup, the hourly refresh, the menu, and sample data.

var SAMPLE_MEMBER_PREFIX = "00000000-0000-4000-8000-";
var SAMPLE_TEAM_PREFIX = "t_sample_";
var SAMPLE_ACCOUNT_PREFIX = "sample_";
var SAMPLE_ENT_USER_PREFIX = "user_sample_";

// Which columns (1-based) carry sample keys in each data tab.
var SAMPLE_KEYS = [
  { tab: TAB_RAW, cols: COLS_RAW, keys: [[1, SAMPLE_MEMBER_PREFIX], [5, SAMPLE_TEAM_PREFIX]] },
  { tab: TAB_LIMITS, cols: COLS_LIMITS, keys: [[1, SAMPLE_ACCOUNT_PREFIX], [4, SAMPLE_MEMBER_PREFIX], [5, SAMPLE_TEAM_PREFIX]] },
  { tab: TAB_PEOPLE, cols: COLS_PEOPLE, keys: [[1, SAMPLE_MEMBER_PREFIX]] },
  { tab: TAB_DEPTS, cols: COLS_DEPTS, keys: [[1, SAMPLE_TEAM_PREFIX]] },
  { tab: TAB_TEAMLABELS, cols: COLS_TEAMLABELS, keys: [[1, SAMPLE_TEAM_PREFIX], [2, SAMPLE_MEMBER_PREFIX]] },
  { tab: TAB_DEVICES, cols: COLS_DEVICES, keys: [[1, SAMPLE_MEMBER_PREFIX]] },
  { tab: TAB_ENT_RAW, cols: COLS_ENT_RAW, keys: [[2, SAMPLE_ENT_USER_PREFIX]] },
  { tab: TAB_ENT_PEOPLE, cols: COLS_ENT_PEOPLE, keys: [[1, SAMPLE_ENT_USER_PREFIX]] }
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

// A new tab has 26 columns; a data tab only needs its own width. Trimming keeps the grid small, but a
// tab with content past its width (the owner's own notes) is left alone.
function trimDataColumns(ss) {
  TAB_SPECS.forEach(function (spec) {
    var sheet = ss.getSheetByName(spec.name);
    if (!sheet) return;
    var max = sheet.getMaxColumns();
    if (max > spec.cols.length && sheet.getLastColumn() <= spec.cols.length) {
      sheet.deleteColumns(spec.cols.length + 1, max - spec.cols.length);
    }
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

// Runs fn under the document lock. refreshAll uses it so two refreshes (hourly trigger, menu, seed)
// never interleave; reports take only the script lock, so they never wait on a refresh.
function withDocumentLock(fn) {
  var lock = LockService.getDocumentLock();
  lock.waitLock(30000);
  try {
    return fn();
  } finally {
    lock.releaseLock();
  }
}

// Reading and rendering run without the script lock, so a slow refresh never makes a report wait: only
// the dashboards and the plan are written, and by refreshAll alone (hence the document lock). The script
// lock is taken only for the tab creation and the 참고팀이름 write.
function refreshAll() {
  withDocumentLock(refreshAllLocked);
}

function refreshAllLocked() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var tz = Session.getScriptTimeZone();
  var nowMs = Date.now();
  var today = localDateString(nowMs, tz);
  withScriptLock(function () { ensureAllTabs(ss); });
  // The pull records its own failures; the catch is for anything unexpected, so the dashboards still render.
  try {
    pullEnterprise(ss, nowMs, tz);
  } catch (e) {
    console.error("pullEnterprise failed: " + (e && e.message));
    try {
      var prev = entReadStatus() || {};
      PropertiesService.getDocumentProperties().setProperty(ENT_STATUS_PROP, JSON.stringify({
        lastRunMs: prev.lastRunMs || null, newestDate: prev.newestDate || null,
        error: entCut("불러오기 실패: " + (e && e.message))
      }));
    } catch (e2) {
      console.error("recording the pull failure failed: " + (e2 && e2.message));
    }
  }
  var data = readAll(ss, tz);
  withScriptLock(function () { writeSuggestedTeamNames(ss, data); });
  DASHBOARD_TABS.forEach(function (d) {
    var sheet = ss.getSheetByName(d.name);
    var lastRow = renderDashboard(sheet, computeDashboard(data, d.kind, today), nowMs, tz);
    renderEnterpriseSection(sheet, lastRow + 3, computeEnterpriseSection(data.enterprise, d.kind, today), data.enterprise, tz);
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
  withScriptLock(function () {
    ensureAllTabs(ss);
    trimDataColumns(ss);
  });
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
    .addItem("Enterprise API 키 넣기", "setEnterpriseKey")
    .addItem("Enterprise API 키 지우기", "clearEnterpriseKey")
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
    var raw = [], limits = [], people = [], depts = [], labels = [], devices = [], entRaw = [], entPeople = [];
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
            // Two fixed Max accounts so the plan tab shows both suggestions: a full-week one (n = 1) and a quiet one (n = 3).
            if (ai === 0 && w > 0 && n === 1) used = 100;
            if (ai === 0 && w > 0 && n === 3) used = 20;
            var readAt = w === 0 ? nowMs - hourMs : resetsAt - hourMs;
            limits.push([a[1], a[0], msToIso(resetsAt), id, dept.team, a[2], "sample.example",
              used, used, msToIso(readAt)]);
          }
        });
        idx++;
      });
    });
    // Enterprise members: two per department plus one with no 부서, over the same days a real backfill covers.
    var entFirst = periodRange("lastMonth", today).prevStart;
    if (entFirst < ENT_FIRST_DATE) entFirst = ENT_FIRST_DATE;
    var entLast = dateToDayNumber(utcDateString(nowMs - DAY_MS));
    var entUsers = [];
    SAMPLE_DEPTS.forEach(function (dept) {
      entUsers.push({ dept: dept.name, code: dept.name === "개발팀" });
      entUsers.push({ dept: dept.name, code: dept.name === "개발팀" });
    });
    entUsers.push({ dept: "", code: false });
    entUsers.forEach(function (u, i) {
      var nn = ("0" + (i + 1)).slice(-2);
      var id = SAMPLE_ENT_USER_PREFIX + nn;
      var email = "sample-ent-" + nn + "@sample.example";
      entPeople.push([id, email, u.dept, entFirst]);
      var level = 1 + ((i * 7) % 5);
      for (var d = dateToDayNumber(entFirst); d <= entLast; d++) {
        if ((i + d) % 6 === 0) continue;   // some days with no activity at all
        var chat = level * 12 + ((d * 5 + i * 3) % 11);
        var zero = (i + d) % 9 === 0;      // a row that exists with 0 messages
        entRaw.push([dayNumberToString(d), id, email, zero ? 0 : chat, zero ? 0 : Math.ceil(chat / 4),
          zero ? 0 : (i % 3 === 0 ? Math.round(chat / 3) : 0), u.code ? 1 + ((d + i) % 4) : 0, nowIso]);
      }
    });
    appendRows(ss.getSheetByName(TAB_RAW), COLS_RAW.length, raw);
    appendRows(ss.getSheetByName(TAB_LIMITS), COLS_LIMITS.length, limits);
    appendRows(ss.getSheetByName(TAB_PEOPLE), COLS_PEOPLE.length, people);
    appendRows(ss.getSheetByName(TAB_DEPTS), COLS_DEPTS.length, depts);
    appendRows(ss.getSheetByName(TAB_TEAMLABELS), COLS_TEAMLABELS.length, labels);
    appendRows(ss.getSheetByName(TAB_DEVICES), COLS_DEVICES.length, devices);
    appendRows(ss.getSheetByName(TAB_ENT_RAW), COLS_ENT_RAW.length, entRaw);
    appendRows(ss.getSheetByName(TAB_ENT_PEOPLE), COLS_ENT_PEOPLE.length, entPeople);
  });
  refreshAll();
}

function clearSampleData() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  withScriptLock(function () { removeSampleRows(ss); });
  refreshAll();
}

// The key goes to the owner's UserProperties only (never a cell, the status or an alert) and is used by
// the owner's own refreshes. Pasting it runs one refresh so the first pull starts right away.
function setEnterpriseKey() {
  var ui = SpreadsheetApp.getUi();
  var res = ui.prompt("Enterprise API 키", "Anthropic 관리자 화면에서 만든 Analytics API 키를 붙여 넣으세요. 이 키는 소유자 계정에만 저장됩니다.", ui.ButtonSet.OK_CANCEL);
  if (res.getSelectedButton() !== ui.Button.OK) return;
  var key = String(res.getResponseText()).trim();
  if (!key) return;
  PropertiesService.getUserProperties().setProperty(ENT_KEY_PROP, key);
  refreshAll();
  ui.alert("키를 저장하고 새로 고쳤습니다. 대시보드 아래 Enterprise 줄에서 결과를 확인하세요.");
}

function clearEnterpriseKey() {
  PropertiesService.getUserProperties().deleteProperty(ENT_KEY_PROP);
  SpreadsheetApp.getUi().alert("키를 지웠습니다. 이미 불러온 데이터는 그대로 남습니다.");
}
