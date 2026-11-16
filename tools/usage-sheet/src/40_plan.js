// Plan tab: per-account weekly-limit forecast and plan suggestion (spec 9.1).
// computePlan is pure; renderPlan writes the sheet.

var PLAN_WINDOW_MS = 7 * 86400000;
var PLAN_STALE_MS = 14 * 86400000;
var PLAN_COL_WIDTHS = [130, 110, 90, 110, 130, 90, 120, 120, 90, 120, 90, 150, 150];
var FORECAST_RANK = { "이미 다 씀": 0, "모자람": 1, "알맞음": 2, "남음": 3, "—": 4 };
var PLAN_HEADERS = ["닉네임", "부서", "도구", "플랜", "이메일 도메인", "이번 주 사용", "막대", "균등하게 썼다면", "리셋까지(일)",
  "이 속도면 리셋 때", "예상", "지난 4주 중 다 쓴 주", "제안"];

function toolDisplay(tool) {
  if (tool === "claude") return "Claude";
  if (tool === "codex") return "Codex";
  return String(tool);
}

function planIndex(order, plan) {
  var want = String(plan).trim().toLowerCase();
  for (var i = 0; i < order.length; i++) {
    if (String(order[i]).toLowerCase() === want) return i;
  }
  return -1;
}

function planSuggestion(plan, tool, fullWeeks, windows, s) {
  if (windows.length < s.suggest_weeks) return "기록 부족";
  var order = s["plan_order_" + tool];
  var idx = order ? planIndex(order, plan) : -1;
  if (fullWeeks >= s.suggest_up_full_weeks) {
    if (idx === -1) return "올리기 검토";
    return idx === order.length - 1 ? "최상위 플랜" : "올리기 검토 → " + order[idx + 1];
  }
  var allLow = windows.length > 0 && windows.every(function (w) { return w.maxUsed < s.suggest_down_max_pct; });
  if (allLow) {
    if (idx === -1) return "내리기 검토";
    return idx === 0 ? "필요한지 검토" : "내리기 검토 → " + order[idx - 1];
  }
  return "유지";
}

function planForecast(cur, projectedPct, s) {
  if (cur && cur.lastUsed >= s.full_week_pct) return "이미 다 씀";
  if (projectedPct === null) return "—";
  if (projectedPct >= s.forecast_short_pct) return "모자람";
  if (projectedPct >= s.forecast_fit_pct) return "알맞음";
  return "남음";
}

// One device per window is the normal case, but a person's two devices report the same weekly window
// separately: merge rows whose reset times are within 24 hours (nearestWindow, like the store). A merged
// window keeps the highest maxUsed; lastUsed, lastReadAt and resetsAt come from its latest-read row.
function mergeWindows(rows) {
  var windows = [];
  rows.slice().sort(function (a, b) { return a.resetsAt - b.resetsAt; }).forEach(function (l) {
    var at = nearestWindow(windows.length, function (k) { return windows[k].resetsAt; }, l.resetsAt);
    if (at === -1) { windows.push(Object.assign({}, l)); return; }
    var w = windows[at];
    w.maxUsed = Math.max(w.maxUsed, l.maxUsed);
    if (l.lastReadAt >= w.lastReadAt) { w.lastUsed = l.lastUsed; w.lastReadAt = l.lastReadAt; w.resetsAt = l.resetsAt; }
  });
  return windows;
}

function computePlan(data, nowMs, tz) {
  var s = data.settings;
  // One group per person (after 합칠대상), account and tool. A poster only ever owns rows under its own
  // memberId, so a stranger reporting someone's account lands in its own group.
  var groups = new Map();
  data.limits.forEach(function (l) {
    var key = canonicalPerson(l.memberId, data.people) + "|" + l.account + "|" + l.tool;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(l);
  });

  // A person's department is the dashboard rule (most days, then tokens, then name) over the last 28 days.
  var todayNum = dateToDayNumber(localDateString(nowMs, tz));
  var recent28 = summarizePeriod(data, dayNumberToString(todayNum - 27), dayNumberToString(todayNum));

  var rows = [];
  var excluded = 0;
  groups.forEach(function (rawList) {
    var latest = rawList.reduce(function (a, b) { return b.lastReadAt > a.lastReadAt ? b : a; });
    var list = mergeWindows(rawList);
    if (latest.lastReadAt < nowMs - PLAN_STALE_MS) return;   // an account nobody has read for 14 days is gone
    var person = canonicalPerson(latest.memberId, data.people);
    var dept = recent28.persons[person] ? personTeam(recent28.persons[person]) : departmentOf(latest.team, data.depts);
    if (!dept) { excluded++; return; }
    var cur = null;
    list.forEach(function (l) { if (l.resetsAt > nowMs && (!cur || l.resetsAt < cur.resetsAt)) cur = l; });
    var done = list.filter(function (l) { return l.resetsAt <= nowMs; })
      .sort(function (a, b) { return b.resetsAt - a.resetsAt; }).slice(0, s.suggest_weeks);
    var fullWeeks = done.filter(function (w) { return w.maxUsed >= s.full_week_pct; }).length;

    var pace = null, projected = null, daysToReset = null;
    if (cur) {
      pace = (PLAN_WINDOW_MS - (cur.resetsAt - cur.lastReadAt)) / PLAN_WINDOW_MS;
      daysToReset = (cur.resetsAt - nowMs) / 86400000;
      var fresh = nowMs - cur.lastReadAt <= s.stale_hours * 3600000;
      if (pace >= s.min_pace && pace <= 1 && fresh) projected = cur.lastUsed / pace;
    }
    rows.push({
      person: person, nickname: nicknameOf(person, data.people), team: dept, tool: latest.tool, plan: latest.plan,
      domain: latest.domain, usedPct: cur ? cur.lastUsed : null, daysToReset: daysToReset,
      pacePct: pace === null ? null : pace * 100, projectedPct: projected,
      forecast: planForecast(cur, projected, s),
      fullWeeks: fullWeeks, finishedWeeks: done.length,
      suggestion: planSuggestion(latest.plan, latest.tool, fullWeeks, done, s)
    });
  });

  rows.sort(function (a, b) {
    var r = FORECAST_RANK[a.forecast] - FORECAST_RANK[b.forecast];
    if (r) return r;
    if (a.projectedPct !== b.projectedPct) {
      if (a.projectedPct === null) return 1;
      if (b.projectedPct === null) return -1;
      return b.projectedPct - a.projectedPct;
    }
    return a.nickname < b.nickname ? -1 : a.nickname > b.nickname ? 1 : 0;
  });

  // Tiles: each person lands in the bucket of their worst account; "—" counts nowhere.
  var worst = new Map();
  rows.forEach(function (r) {
    var rank = FORECAST_RANK[r.forecast];
    if (rank === 4) return;
    if (!worst.has(r.person) || rank < worst.get(r.person)) worst.set(r.person, rank);
  });
  var tiles = { short: 0, fit: 0, spare: 0, noInfo: 0 };
  worst.forEach(function (rank) {
    if (rank <= 1) tiles.short++; else if (rank === 2) tiles.fit++; else tiles.spare++;
  });

  var today = dateToDayNumber(localDateString(nowMs, tz));
  var weekStart = dayNumberToString(today - 6);
  var recent = Object.create(null);
  data.usage.forEach(function (u) {
    if (u.date < weekStart || !departmentOf(u.team, data.depts)) return;
    recent[canonicalPerson(u.memberId, data.people)] = true;
  });
  var informed = Object.create(null);
  data.limits.forEach(function (l) {
    if (l.lastReadAt >= nowMs - PLAN_WINDOW_MS) informed[canonicalPerson(l.memberId, data.people)] = true;
  });
  Object.keys(recent).forEach(function (id) { if (!informed[id]) tiles.noInfo++; });

  rows.forEach(function (r) { delete r.person; });
  return { tiles: tiles, rows: rows, excludedAccounts: excluded, suggestWeeks: s.suggest_weeks };
}

function renderPlan(sheet, model, nowMs, tz) {
  var n = model.rows.length;
  var lastRow = Math.max(7 + n + 6, 20);
  ensureRows(sheet, lastRow);
  sheet.clear();
  sheet.getCharts().forEach(function (c) { sheet.removeChart(c); });

  sheet.getRange(1, 1).setValue(asText("플랜과 주간 한도 — 지금 진행 중인 주"));
  sheet.getRange(2, 1).setValue(asText("마지막 갱신: " + Utilities.formatDate(new Date(nowMs), tz, "yyyy-MM-dd HH:mm")));
  var t = model.tiles;
  sheet.getRange(4, 1, 1, 4).setValues(asTextRows([["이번 주 모자랄 사람", "알맞게 쓸 사람", "남길 사람", "플랜 정보 없음"]])).setFontWeight("bold");
  sheet.getRange(5, 1, 1, 4).setValues([[t.short, t.fit, t.spare, t.noInfo]]);
  sheet.getRange(7, 1, 1, PLAN_HEADERS.length).setValues(asTextRows([PLAN_HEADERS])).setFontWeight("bold");

  if (n > 0) {
    var body = model.rows.map(function (r) {
      return [r.nickname, r.team, toolDisplay(r.tool), r.plan, r.domain, r.usedPct, "", r.pacePct, r.daysToReset,
        r.projectedPct, r.forecast, r.fullWeeks + " / " + model.suggestWeeks, r.suggestion].map(function (v) { return v === null ? "" : v; });
    });
    sheet.getRange(8, 1, n, PLAN_HEADERS.length).setValues(asTextRows(body));
    [6, 8, 10].forEach(function (col) { sheet.getRange(8, col, n, 1).setNumberFormat('0.0"%"'); });
    sheet.getRange(8, 9, n, 1).setNumberFormat("0.0");
    for (var i = 0; i < n; i++) {
      var row = 8 + i;
      sheet.getRange(row, 7).setFormula('=SPARKLINE(F' + row + ',{"charttype","bar";"max",100})');
    }
  }

  var note = 8 + n + 1;
  sheet.getRange(note, 1).setValue(asText("미지정 부서라 빠진 계정: " + model.excludedAccounts + "개"));
  sheet.getRange(note + 2, 1, 3, 1).setValues(asTextRows([
    ["\"가장 높은 사용률\"은 앱이 켜져 있을 때 읽은 값 중 최대입니다. 주 끝 무렵에 앱이 꺼져 있었으면 실제보다 낮게 잡힙니다."],
    ["지난 4주 기록은 이 기능이 들어간 뒤부터 쌓입니다. 처음 4주 동안 제안은 \"기록 부족\"입니다."],
    ["한도 사용률과 리셋 시각은 Anthropic이 정한 값을 앱이 읽은 것입니다. Anthropic이 한도 규칙을 바꾸면 해석도 달라질 수 있습니다."]
  ]));

  PLAN_COL_WIDTHS.forEach(function (px, i) { sheet.setColumnWidth(i + 1, px); });
}
