// Enterprise members: the Analytics API client, the record parser, the day picker, the writer and the
// reader. The API key lives in UserProperties only; the pull status (no secret) in DocumentProperties.

function utcDateString(ms) {
  return new Date(ms).toISOString().slice(0, 10);
}

// A missing object or null value counts as 0.
function entNum(v) {
  return typeof v === "number" && isFinite(v) ? v : 0;
}

function entGet(obj, path) {
  var cur = obj;
  for (var i = 0; i < path.length; i++) {
    if (!isPlainObject(cur)) return 0;
    cur = cur[path[i]];
  }
  return entNum(cur);
}

// One API record -> one 엔터프라이즈 원본 row, or null when the record has no user id. Chat and Cowork
// usage moves into chat_cowork_unified_metrics when a member switches, so both blocks are summed.
function entRecordToRow(rec, date, nowIso) {
  if (!isPlainObject(rec) || !isPlainObject(rec.user) || typeof rec.user.id !== "string" || rec.user.id === "") return null;
  var email = typeof rec.user.email_address === "string" ? rec.user.email_address : "";
  var chat = entGet(rec, ["chat_metrics", "message_count"]) +
    entGet(rec, ["chat_cowork_unified_metrics", "chat", "message_count"]);
  var conv = entGet(rec, ["chat_metrics", "distinct_conversation_count"]) +
    entGet(rec, ["chat_cowork_unified_metrics", "chat", "distinct_conversation_count"]);
  var coworkMsg = entGet(rec, ["cowork_metrics", "message_count"]) +
    entGet(rec, ["chat_cowork_unified_metrics", "sessions", "message_count"]);
  var codeSessions = entGet(rec, ["claude_code_metrics", "core_metrics", "distinct_session_count"]);
  return [date, rec.user.id, email, chat, conv, coworkMsg, codeSessions, nowIso];
}

// Ascending days in [first, yesterday] that are not fetched yet, plus the last recentDays days (the API
// revises recent values), without duplicates.
function entDaysToFetch(fetched, first, yesterday, recentDays) {
  var a = dateToDayNumber(first), b = dateToDayNumber(yesterday);
  var out = [];
  if (a === null || b === null || a > b) return out;
  for (var d = a; d <= b; d++) {
    var s = dayNumberToString(d);
    if (!fetched.has(s) || d > b - recentDays) out.push(s);
  }
  return out;
}

// Fetches one UTC day, following next_page. budget: { left, sent } is shared by the whole run.
function entFetchDay(key, date, budget) {
  var records = [];
  var page = null;
  do {
    if (budget.left <= 0) return { kind: "budget" };
    var url = ENT_API_URL + "?date=" + date + "&limit=" + ENT_PAGE_LIMIT;
    if (page !== null) url += "&page=" + encodeURIComponent(page);
    if (budget.sent > 0) Utilities.sleep(ENT_SLEEP_MS);
    budget.left--;
    budget.sent++;
    var res = UrlFetchApp.fetch(url, {
      method: "get",
      headers: { "x-api-key": key, "anthropic-version": ENT_API_VERSION },
      muteHttpExceptions: true
    });
    var code = res.getResponseCode();
    var parsed;
    try { parsed = JSON.parse(res.getContentText()); } catch (e) { parsed = undefined; }
    if (code !== 200) return { kind: "http", code: code, body: parsed === undefined ? null : parsed };
    if (!isPlainObject(parsed) || !Array.isArray(parsed.data)) return { kind: "bad_json" };
    records = records.concat(parsed.data);
    page = typeof parsed.next_page === "string" && parsed.next_page !== "" ? parsed.next_page : null;
  } while (page !== null);
  return { kind: "ok", records: records };
}

function entHttpError(code, body) {
  var e = isPlainObject(body) ? body.error : null;
  if (isPlainObject(e) && typeof e.type === "string" && typeof e.message === "string") {
    return code + " " + e.type + ": " + e.message;
  }
  return code + " 응답";
}

function entCut(text) {
  return text.length > 200 ? text.slice(0, 200) : text;
}

function entReadStatus() {
  var raw = PropertiesService.getDocumentProperties().getProperty(ENT_STATUS_PROP);
  if (!raw) return null;
  try {
    var s = JSON.parse(raw);
    return isPlainObject(s) ? s : null;
  } catch (e) {
    return null;
  }
}

function entLoggedDates(ss, tz) {
  var sheet = ss.getSheetByName(TAB_ENT_LOG);
  var out = new Set();
  if (!sheet) return out;
  sheetColumns(sheet, [[1, 1]]).forEach(function (r) {
    var d = cellToDateString(r[0], tz);
    if (d) out.add(d);
  });
  return out;
}

// Call inside the script lock. days: [{ date, rows }].
function writeEnterprise(ss, days, nowMs, tz) {
  var nowIso = msToIso(nowMs);
  var today = localDateString(nowMs, tz);
  var rawItems = [], logItems = [], personItems = [];
  var seen = new Set();
  days.forEach(function (day) {
    day.rows.forEach(function (row) {
      rawItems.push({ key: row[0] + "|" + row[1], build: function () { return row; } });
      if (seen.has(row[1])) return;
      seen.add(row[1]);
      personItems.push({
        key: row[1],
        // 부서 (C) belongs to the owner: an existing row gets column B only.
        build: function (old) {
          if (old === null) return [row[1], row[2], "", today];
          return [old[0], row[2] || old[1], old[2], old[3]];
        }
      });
    });
    logItems.push({ key: day.date, build: function () { return [day.date, nowIso, day.rows.length]; } });
  });
  ensureSheets(ss);
  upsertRows(ss.getSheetByName(TAB_ENT_RAW), COLS_ENT_RAW.length, function (r) {
    return cellToDateString(r[0], tz) + "|" + r[1];
  }, rawItems, { readWidth: 2 });
  upsertRows(ss.getSheetByName(TAB_ENT_PEOPLE), COLS_ENT_PEOPLE.length, function (r) { return r[0]; },
    personItems, { spans: [[2, 1]] });
  upsertRows(ss.getSheetByName(TAB_ENT_LOG), COLS_ENT_LOG.length, function (r) {
    return cellToDateString(r[0], tz);
  }, logItems, { readWidth: 1 });
}

function entNewestLoggedDate(ss, tz) {
  var newest = null;
  entLoggedDates(ss, tz).forEach(function (d) { if (newest === null || d > newest) newest = d; });
  return newest;
}

// Pulls the missing and the recent days for the running user. The fetching holds no lock; the writes
// take the script lock once. A run that stops early still saves every day it completed.
function pullEnterprise(ss, nowMs, tz) {
  var key = PropertiesService.getUserProperties().getProperty(ENT_KEY_PROP);
  if (!key) return { skipped: true };
  var nowIso = msToIso(nowMs);
  var first = periodRange("lastMonth", localDateString(nowMs, tz)).prevStart;
  if (first < ENT_FIRST_DATE) first = ENT_FIRST_DATE;
  var yesterday = utcDateString(nowMs - DAY_MS);
  var recentFrom = dayNumberToString(dateToDayNumber(yesterday) - (ENT_RECENT_DAYS - 1));
  var days = entDaysToFetch(entLoggedDates(ss, tz), first, yesterday, ENT_RECENT_DAYS);
  var budget = { left: ENT_MAX_REQUESTS, sent: 0 };
  var collected = [];
  var error = null;
  try {
    for (var i = 0; i < days.length; i++) {
      var r = entFetchDay(key, days[i], budget);
      if (r.kind === "budget") break;
      if (r.kind === "bad_json") { error = "응답을 읽지 못했습니다"; break; }
      if (r.kind === "http") {
        // The newest days answer 400 until the API has them: normal, not an error.
        if (r.code === 400 && days[i] >= recentFrom) break;
        error = entHttpError(r.code, r.body);
        break;
      }
      var rows = [];
      r.records.forEach(function (rec) {
        var row = entRecordToRow(rec, days[i], nowIso);
        if (row !== null) rows.push(row);
      });
      collected.push({ date: days[i], rows: rows });
    }
  } catch (e) {
    error = "요청 실패: " + (e && e.message ? e.message : String(e));
  }
  if (error !== null) error = entCut(error);
  withScriptLock(function () {
    writeEnterprise(ss, collected, nowMs, tz);
    var old = entReadStatus();
    var status = {
      lastRunMs: error === null ? nowMs : (old && typeof old.lastRunMs === "number" ? old.lastRunMs : null),
      newestDate: entNewestLoggedDate(ss, tz),
      error: error
    };
    PropertiesService.getDocumentProperties().setProperty(ENT_STATUS_PROP, JSON.stringify(status));
  });
  return { saved: collected.length, error: error };
}

function readEnterprise(ss, tz) {
  function rowsOf(name, cols) {
    var sheet = ss.getSheetByName(name);
    return sheet ? sheetRows(sheet, cols.length) : [];
  }
  var usage = rowsOf(TAB_ENT_RAW, COLS_ENT_RAW).map(function (r) {
    return {
      date: cellToDateString(r[0], tz), userId: String(r[1]), email: String(r[2]),
      chat: Number(r[3]) || 0, conv: Number(r[4]) || 0, cowork: Number(r[5]) || 0, code: Number(r[6]) || 0
    };
  });
  var people = Object.create(null);
  rowsOf(TAB_ENT_PEOPLE, COLS_ENT_PEOPLE).forEach(function (r) {
    people[String(r[0])] = { email: String(r[1]), dept: String(r[2]).trim() };
  });
  return {
    usage: usage,
    people: people,
    status: entReadStatus(),
    hasKey: !!PropertiesService.getUserProperties().getProperty(ENT_KEY_PROP)
  };
}
