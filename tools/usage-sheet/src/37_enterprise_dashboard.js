// Enterprise section of the period dashboards: the pure section model (computeEnterpriseSection),
// the status line, and the sheet writer. Messages are chat + cowork; "people" are users with a row.

function entDisplayName(userId, email) {
  var e = String(email || "");
  var at = e.indexOf("@");
  var name = at > 0 ? e.slice(0, at) : e;
  return name || String(userId);
}

// Per-user totals over [start, end]; users with a row count even when every value is 0.
function summarizeEnterprise(ent, start, end) {
  var persons = Object.create(null);
  var unassignedPeople = Object.create(null);
  var unassignedMessages = 0;
  var any = false;
  ent.usage.forEach(function (r) {
    if (r.date < start || r.date > end) return;
    any = true;
    var info = ent.people[r.userId];
    var dept = info && info.dept ? String(info.dept).trim() : "";
    var messages = r.chat + r.cowork;
    if (!dept) {
      unassignedPeople[r.userId] = true;
      unassignedMessages += messages;
      return;
    }
    var p = persons[r.userId] || (persons[r.userId] = { userId: r.userId, email: r.email, dept: dept, messages: 0, code: 0 });
    if (r.email) p.email = r.email;
    p.messages += messages;
    p.code += r.code;
  });
  var teams = Object.create(null);
  var total = 0, peopleCount = 0;
  Object.keys(persons).forEach(function (id) {
    var p = persons[id];
    total += p.messages; peopleCount++;
    var t = teams[p.dept] || (teams[p.dept] = { messages: 0, people: 0 });
    t.messages += p.messages; t.people++;
  });
  return {
    any: any, persons: persons, teams: teams, total: total, people: peopleCount,
    perPerson: peopleCount ? total / peopleCount : 0,
    unassigned: { people: Object.keys(unassignedPeople).length, messages: unassignedMessages }
  };
}

// The API data arrives a day or two late, so the period is counted only up to the newest data day and the
// previous period is cut to the same length; otherwise flat usage would read as a drop.
function computeEnterpriseSection(ent, kind, today) {
  var range = periodRange(kind, today);
  var newest = null;
  if (ent.status && dateToDayNumber(ent.status.newestDate) !== null) newest = ent.status.newestDate;
  ent.usage.forEach(function (r) { if (r.date && (newest === null || r.date > newest)) newest = r.date; });
  var dataEnd = newest === null || newest > range.end ? range.end : newest;
  var counted = { start: range.start, end: dataEnd };
  var cur, prev;
  if (newest === null || dataEnd < range.start) {
    cur = summarizeEnterprise({ usage: [], people: ent.people }, range.start, range.end);
    prev = cur;
    counted = null;
  } else {
    var length = dateToDayNumber(dataEnd) - dateToDayNumber(range.start);
    var prevEndNumber = Math.min(dateToDayNumber(range.prevEnd), dateToDayNumber(range.prevStart) + length);
    cur = summarizeEnterprise(ent, range.start, dataEnd);
    prev = summarizeEnterprise(ent, range.prevStart, dayNumberToString(prevEndNumber));
  }
  function byName(a, b) { return a < b ? -1 : a > b ? 1 : 0; }
  var depts = Object.keys(cur.teams).map(function (name) {
    var t = cur.teams[name];
    return { name: name, messages: t.messages, perPerson: t.people ? t.messages / t.people : 0, people: t.people };
  }).sort(function (a, b) { return b.messages - a.messages || byName(a.name, b.name); });
  var list = Object.keys(cur.persons).map(function (id) {
    var p = cur.persons[id];
    var info = ent.people[id];
    return { name: entDisplayName(id, (info && info.email) || p.email), dept: p.dept, messages: p.messages, code: p.code };
  });
  var top = list.slice().sort(function (a, b) { return b.messages - a.messages || byName(a.name, b.name); }).slice(0, 5);
  var inTop = new Set(top);
  var bottom = list.slice().sort(function (a, b) { return a.messages - b.messages || byName(a.name, b.name); })
    .filter(function (p) { return !inTop.has(p); }).slice(0, 5);
  return {
    hasData: cur.any,
    counted: counted,
    tiles: {
      messages: cur.total, perPerson: cur.perPerson, people: cur.people, deptCount: depts.length,
      deltaMessagesPct: pctChange(cur.total, prev.total),
      deltaPerPersonPct: pctChange(cur.perPerson, prev.perPerson),
      deltaPeople: cur.people - prev.people
    },
    depts: depts, top: top, bottom: bottom, unassigned: cur.unassigned
  };
}

function enterpriseStatusLine(status, hasKey, tz) {
  var line;
  if (!status && !hasKey) {
    line = "Enterprise 키가 없습니다 — 메뉴 > Enterprise API 키 넣기";
  } else if (status && status.lastRunMs) {
    line = "마지막 불러옴: " + Utilities.formatDate(new Date(status.lastRunMs), tz, "yyyy-MM-dd HH:mm") +
      " · 데이터: " + (status.newestDate || "없음") + "까지";
  } else {
    line = "아직 불러오지 못했습니다";
  }
  if (status && status.error) line += " · 오류: " + status.error;
  return line;
}

// Writes the section from startRow down and returns the last row used. The caller has already cleared the sheet.
function renderEnterpriseSection(sheet, startRow, model, ent, tz) {
  var s = startRow;
  if (!model.hasData) {
    ensureRows(sheet, s + 1);
    sheet.getRange(s, 1).setValue(asText("Enterprise 멤버 (Claude 관리자 통계)")).setFontWeight("bold");
    sheet.getRange(s + 1, 1).setValue(asText(enterpriseStatusLine(ent.status, ent.hasKey, tz)));
    return s + 1;
  }
  var n = model.depts.length;
  var tablesEnd = Math.max(s + 7 + n, s + 20);
  var unassignedRow = tablesEnd + 2;
  var lastRow = unassignedRow + 6;
  ensureRows(sheet, lastRow);

  sheet.getRange(s, 1).setValue(asText("Enterprise 멤버 (Claude 관리자 통계)")).setFontWeight("bold");
  sheet.getRange(s + 1, 1).setValue(asText(enterpriseStatusLine(ent.status, ent.hasKey, tz)));
  sheet.getRange(s + 2, 1).setValue(asText("센 날짜: " + model.counted.start + " ~ " + model.counted.end + " (이전 기간도 같은 길이)"));

  var t = model.tiles;
  sheet.getRange(s + 3, 1, 1, 4).setValues(asTextRows([["메시지", "1인 평균", "쓰는 사람", "부서 수"]])).setFontWeight("bold");
  sheet.getRange(s + 4, 1, 1, 4).setValues([[t.messages, t.perPerson, t.people, t.deptCount]]);
  sheet.getRange(s + 4, 1, 1, 1).setNumberFormat("#,##0");
  sheet.getRange(s + 4, 2, 1, 1).setNumberFormat("#,##0.0");
  sheet.getRange(s + 4, 3, 1, 2).setNumberFormat("#,##0");
  sheet.getRange(s + 5, 1, 1, 4).setValues(asTextRows([[formatDeltaPct(t.deltaMessagesPct), formatDeltaPct(t.deltaPerPersonPct),
    formatDeltaPeople(t.deltaPeople), ""]]));

  var deptRows = [["부서", "메시지", "1인 평균", "인원"]];
  model.depts.forEach(function (d) { deptRows.push([d.name, d.messages, d.perPerson, d.people]); });
  sheet.getRange(s + 7, 1, n + 1, 4).setValues(asTextRows(deptRows));
  sheet.getRange(s + 7, 1, 1, 4).setFontWeight("bold");
  if (n > 0) {
    sheet.getRange(s + 8, 2, n, 1).setNumberFormat("#,##0");
    sheet.getRange(s + 8, 3, n, 1).setNumberFormat("#,##0.0");
    sheet.getRange(s + 8, 4, n, 1).setNumberFormat("#,##0");
  }

  function personTable(row, title, people) {
    var rows = [[title, "부서", "메시지", "Claude Code 세션"]];
    people.forEach(function (p) { rows.push([p.name, p.dept, p.messages, p.code]); });
    sheet.getRange(row, 6, rows.length, 4).setValues(asTextRows(rows));
    sheet.getRange(row, 6, 1, 4).setFontWeight("bold");
    if (people.length) sheet.getRange(row + 1, 8, people.length, 2).setNumberFormat("#,##0");
  }
  personTable(s + 7, "많이 쓰는 사람", model.top);
  personTable(s + 15, "적게 쓰는 사람", model.bottom);

  sheet.getRange(unassignedRow, 1).setValue(asText("미지정: " + model.unassigned.people + "명 · " + model.unassigned.messages +
    " 메시지 — 엔터프라이즈 사람 탭에 부서를 적으면 포함됩니다"));
  sheet.getRange(unassignedRow + 2, 1, 5, 1).setValues(asTextRows([
    ["Enterprise 조직 멤버만, Anthropic 관리자 통계 기준입니다. 하루 늦게(보통 다음 날 밤 10시쯤) 채워집니다."],
    ["날짜는 UTC 하루 기준이라 한국 날짜와 9시간 어긋납니다."],
    ["메시지 = 채팅 + Cowork 메시지. Claude Code 사용은 세션 수로 따로 셉니다."],
    ["부서는 엔터프라이즈 사람 탭에서 정합니다. 비어 있으면 미지정입니다."],
    ["관리자 통계에 안 나온 사람은 보이지 않습니다."]
  ]));

  if (n > 0) {
    var chart = sheet.newChart()
      .setChartType(Charts.ChartType.BAR)
      .addRange(sheet.getRange(s + 7, 1, n + 1, 1))
      .addRange(sheet.getRange(s + 7, 2, n + 1, 1))
      .setNumHeaders(1)
      .setPosition(s + 3, 10, 0, 0)
      .setOption("title", "부서별 메시지 (Enterprise)")
      .setOption("width", CHART_WIDTH)
      .setOption("height", CHART_HEIGHT)
      .setOption("legend", { position: "none" })
      .build();
    sheet.insertChart(chart);
  }
  sheet.setColumnWidth(9, 110);
  return lastRow;
}
