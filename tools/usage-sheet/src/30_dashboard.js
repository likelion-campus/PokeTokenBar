// Period dashboards: pure computation (periodRange, computeDashboard) plus the sheet writer.
// All date math runs on "yyyy-MM-dd" strings through Date.UTC, never local-time Dates.

var TOKEN_FORMAT = '#,##0.0,,"M"';
var MAX_MERGE_HOPS = 5;
var SORTED_COL = 20;
var CHART_WIDTH = 480;
var CHART_HEIGHT = 300;

function dayNumberToString(n) {
  var d = new Date(n * DAY_MS);
  var m = d.getUTCMonth() + 1, day = d.getUTCDate();
  return d.getUTCFullYear() + "-" + (m < 10 ? "0" : "") + m + "-" + (day < 10 ? "0" : "") + day;
}

function monthStartNumber(y, m0) { return Date.UTC(y, m0, 1) / DAY_MS; }

function periodRange(kind, today) {
  var t = dateToDayNumber(today);
  var y = Number(today.slice(0, 4)), m0 = Number(today.slice(5, 7)) - 1;
  var start, end, prevStart, prevEnd, label;
  if (kind === "last7") {
    start = t - 6; end = t; prevStart = t - 13; prevEnd = t - 7; label = "지난 7일";
  } else if (kind === "lastMonth") {
    var thisStart = monthStartNumber(y, m0);
    var prevMonthStart = monthStartNumber(y, m0 - 1);
    start = prevMonthStart; end = thisStart - 1;
    prevStart = monthStartNumber(y, m0 - 2); prevEnd = prevMonthStart - 1;
    label = "지난달";
  } else {
    var monthStart = monthStartNumber(y, m0);
    var pStart = monthStartNumber(y, m0 - 1);
    var prevLen = monthStart - pStart;
    var dayOfMonth = t - monthStart + 1;
    start = monthStart; end = t;
    prevStart = pStart; prevEnd = pStart + Math.min(dayOfMonth, prevLen) - 1;
    label = "이번 달";
  }
  return {
    start: dayNumberToString(start), end: dayNumberToString(end),
    prevStart: dayNumberToString(prevStart), prevEnd: dayNumberToString(prevEnd),
    title: label + " (" + dayNumberToString(start) + " ~ " + dayNumberToString(end) + ")"
  };
}

// Follows mergeInto up to MAX_MERGE_HOPS. A cycle returns the id itself; a missing target stops at
// the last id that has a row; a chain longer than the limit stops where it ran out.
function canonicalPerson(memberId, people) {
  var seen = Object.create(null);
  var current = memberId;
  seen[current] = true;
  for (var hop = 0; hop < MAX_MERGE_HOPS; hop++) {
    var row = people[current];
    if (!row || !row.mergeInto) return current;
    var next = row.mergeInto;
    if (next === current) return current;
    if (seen[next]) return memberId;
    if (!people[next]) return current;
    seen[next] = true;
    current = next;
  }
  return current;
}

function departmentOf(team, depts) {
  var d = depts[team];
  return d && d.name ? String(d.name).trim() : "";
}

// Summarizes assigned rows in [start, end] (yyyy-MM-dd strings compare correctly as text).
function summarizePeriod(data, start, end) {
  var persons = Object.create(null);   // canonical id -> { total, depts: name -> { dates, total } }
  var teams = Object.create(null);     // dept name -> { total, people: set }
  var unassignedPeople = Object.create(null);
  var unassignedTotal = 0;
  data.usage.forEach(function (r) {
    if (r.date < start || r.date > end) return;
    var person = canonicalPerson(r.memberId, data.people);
    var dept = departmentOf(r.team, data.depts);
    if (!dept) {
      unassignedPeople[person] = true;
      unassignedTotal += r.total;
      return;
    }
    var p = persons[person] || (persons[person] = { total: 0, depts: Object.create(null) });
    p.total += r.total;
    var pd = p.depts[dept] || (p.depts[dept] = { dates: Object.create(null), total: 0 });
    pd.dates[r.date] = true;
    pd.total += r.total;
    var t = teams[dept] || (teams[dept] = { total: 0, people: Object.create(null) });
    t.total += r.total;
    t.people[person] = true;
  });
  var total = 0, peopleCount = 0;
  Object.keys(persons).forEach(function (id) { total += persons[id].total; peopleCount++; });
  return {
    persons: persons, teams: teams, total: total, people: peopleCount,
    perPerson: peopleCount ? total / peopleCount : 0,
    teamCount: Object.keys(teams).length,
    unassigned: { people: Object.keys(unassignedPeople).length, total: unassignedTotal }
  };
}

function pctChange(cur, prev) {
  if (!prev) return null;
  return Math.round((cur - prev) / prev * 1000) / 10;
}

function personTeam(p) {
  var best = null, bestDays = -1, bestTotal = -1;
  Object.keys(p.depts).forEach(function (name) {
    var days = Object.keys(p.depts[name].dates).length, tot = p.depts[name].total;
    var better = days > bestDays || (days === bestDays && (tot > bestTotal || (tot === bestTotal && name < best)));
    if (better) { best = name; bestDays = days; bestTotal = tot; }
  });
  return best || "";
}

function nicknameOf(id, people) {
  var row = people[id];
  var nick = row && row.nickname ? String(row.nickname) : "";
  return nick || String(id).slice(0, 8);
}

function computeDashboard(data, kind, today) {
  var range = periodRange(kind, today);
  var cur = summarizePeriod(data, range.start, range.end);
  var prev = summarizePeriod(data, range.prevStart, range.prevEnd);

  var teams = Object.keys(cur.teams).map(function (name) {
    var t = cur.teams[name], n = Object.keys(t.people).length;
    return { name: name, total: t.total, perPerson: n ? t.total / n : 0, people: n };
  }).sort(function (a, b) { return b.total - a.total || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0); });

  var list = Object.keys(cur.persons).map(function (id) {
    return { nickname: nicknameOf(id, data.people), team: personTeam(cur.persons[id]), total: cur.persons[id].total };
  });
  function byNick(a, b) { return a.nickname < b.nickname ? -1 : a.nickname > b.nickname ? 1 : 0; }
  var top = list.slice().sort(function (a, b) { return b.total - a.total || byNick(a, b); }).slice(0, 5);
  var inTop = new Set(top);
  var bottom = list.slice().sort(function (a, b) { return a.total - b.total || byNick(a, b); })
    .filter(function (p) { return !inTop.has(p); }).slice(0, 5);

  return {
    title: range.title,
    tiles: {
      total: cur.total, perPerson: cur.perPerson, people: cur.people, teamCount: cur.teamCount,
      deltaTotalPct: pctChange(cur.total, prev.total),
      deltaPerPersonPct: pctChange(cur.perPerson, prev.perPerson),
      deltaPeople: cur.people - prev.people
    },
    teams: teams, top: top, bottom: bottom, unassigned: cur.unassigned
  };
}

function formatDeltaPct(v) {
  if (v === null || v === undefined) return "—";
  return (v > 0 ? "+" : "") + v.toFixed(1) + "%";
}

function formatDeltaPeople(v) {
  return (v > 0 ? "+" : "") + v + "명";
}

function tokensText(n) { return (n / 1e6).toFixed(1) + "M"; }

function renderDashboard(sheet, model, nowMs, tz) {
  var n = model.teams.length;
  var teamEnd = 8 + n;
  // Below both the team table and the F:H person tables (the last one ends at row 21).
  var noteRow = Math.max(teamEnd, 21) + 2;
  var lastRow = Math.max(noteRow + 4, 21);
  ensureRows(sheet, lastRow);
  sheet.clear();
  sheet.getCharts().forEach(function (c) { sheet.removeChart(c); });

  var t = model.tiles;
  sheet.getRange(1, 1).setValue(asText(model.title));
  sheet.getRange(2, 1).setValue(asText("마지막 갱신: " + Utilities.formatDate(new Date(nowMs), tz, "yyyy-MM-dd HH:mm")));
  sheet.getRange(4, 1, 1, 4).setValues(asTextRows([["전체 토큰", "1인 평균", "쓰는 사람", "팀 수"]])).setFontWeight("bold");
  sheet.getRange(5, 1, 1, 4).setValues([[t.total, t.perPerson, t.people, t.teamCount]]);
  sheet.getRange(6, 1, 1, 4).setValues(asTextRows([[formatDeltaPct(t.deltaTotalPct), formatDeltaPct(t.deltaPerPersonPct),
    formatDeltaPeople(t.deltaPeople), ""]]));
  sheet.getRange(5, 1, 1, 2).setNumberFormat(TOKEN_FORMAT);

  var teamRows = [["부서", "총 토큰", "1인 평균", "인원"]];
  model.teams.forEach(function (x) { teamRows.push([x.name, x.total, x.perPerson, x.people]); });
  sheet.getRange(8, 1, n + 1, 4).setValues(asTextRows(teamRows));
  sheet.getRange(8, 1, 1, 4).setFontWeight("bold");
  if (n > 0) sheet.getRange(9, 2, n, 2).setNumberFormat(TOKEN_FORMAT);

  function personTable(row, title, people) {
    var rows = [[title, "부서", "토큰"]];
    people.forEach(function (p) { rows.push([p.nickname, p.team, p.total]); });
    sheet.getRange(row, 6, rows.length, 3).setValues(asTextRows(rows));
    sheet.getRange(row, 6, 1, 3).setFontWeight("bold");
    if (people.length) sheet.getRange(row + 1, 8, people.length, 1).setNumberFormat(TOKEN_FORMAT);
  }
  personTable(8, "많이 쓰는 팀원", model.top);
  personTable(16, "적게 쓰는 팀원", model.bottom);

  sheet.getRange(noteRow, 1).setValue(asText("미지정: " + model.unassigned.people + "명 · " + tokensText(model.unassigned.total) +
    " 토큰 — 부서 탭에 이름을 적으면 포함됩니다"));
  sheet.getRange(noteRow + 2, 1, 3, 1).setValues(asTextRows([
    ["앱이 없거나 팀 기능을 끈 사람은 아예 보이지 않습니다. 그래서 \"적게 쓰는 팀원\"에도 잡히지 않습니다."],
    ["인원과 평균은 \"앱이 보낸 사람\" 기준입니다."],
    ["숫자는 실제 청구액이 아니라 각자 기기의 로그에서 센 값입니다. 앱을 켜 둔 기기의 사용량만 잡힙니다."]
  ]));

  // Chart 2 is bound to a copy of the department and 1인 평균 columns sorted by the per-person value
  // (descending), far to the right (T:U) beyond the visible layout.
  var byPerson = model.teams.slice().sort(function (a, b) {
    return b.perPerson - a.perPerson || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
  });
  var sorted = [["부서 (1인 평균순)", "1인 평균"]];
  byPerson.forEach(function (x) { sorted.push([x.name, x.perPerson]); });
  sheet.getRange(8, SORTED_COL, n + 1, 2).setValues(asTextRows(sorted));
  sheet.getRange(8, SORTED_COL, 1, 2).setFontWeight("bold");
  if (n > 0) sheet.getRange(9, SORTED_COL + 1, n, 1).setNumberFormat(TOKEN_FORMAT);

  // The two charts sit side by side: both are CHART_WIDTH x CHART_HEIGHT and start at J4, the second
  // CHART_WIDTH + 20 px to the right of the first.
  if (n > 0) {
    [
      { title: "팀별 총 사용량", labels: [8, 1], values: [8, 2], offsetX: 0 },
      { title: "팀별 1인 평균", labels: [8, SORTED_COL], values: [8, SORTED_COL + 1], offsetX: CHART_WIDTH + 20 }
    ].forEach(function (spec) {
      var chart = sheet.newChart()
        .setChartType(Charts.ChartType.BAR)
        .addRange(sheet.getRange(spec.labels[0], spec.labels[1], n + 1, 1))
        .addRange(sheet.getRange(spec.values[0], spec.values[1], n + 1, 1))
        .setPosition(4, 10, spec.offsetX, 0)
        .setOption("title", spec.title)
        .setOption("width", CHART_WIDTH)
        .setOption("height", CHART_HEIGHT)
        .setOption("legend", { position: "none" })
        .build();
      sheet.insertChart(chart);
    });
  }

  [120, 100, 100, 100, 30, 130, 110, 100].forEach(function (px, i) { sheet.setColumnWidth(i + 1, px); });
  return lastRow;
}
