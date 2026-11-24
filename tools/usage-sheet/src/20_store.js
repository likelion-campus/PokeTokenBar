// Sheet storage: tab setup, upserts, the device check and the readers. Key lookups use Map
// (or null-prototype objects) because keys come from outside.

var TAB_SPECS = [
  { name: TAB_RAW, cols: COLS_RAW, textCols: [3] },
  { name: TAB_LIMITS, cols: COLS_LIMITS, textCols: [3, 10] },
  { name: TAB_PEOPLE, cols: COLS_PEOPLE, textCols: [] },
  { name: TAB_DEPTS, cols: COLS_DEPTS, textCols: [4] },
  { name: TAB_TEAMLABELS, cols: COLS_TEAMLABELS, textCols: [], hidden: true },
  { name: TAB_DEVICES, cols: COLS_DEVICES, textCols: [], hidden: true },
  // 값 stays text so a typed "70%" is not turned into 0.7.
  { name: TAB_SETTINGS, cols: COLS_SETTINGS, textCols: [2] },
  { name: TAB_ENT_RAW, cols: COLS_ENT_RAW, textCols: [1] },
  { name: TAB_ENT_PEOPLE, cols: COLS_ENT_PEOPLE, textCols: [4] },
  { name: TAB_ENT_LOG, cols: COLS_ENT_LOG, textCols: [1], hidden: true }
];

// Creates every missing data tab. Existing tabs are left alone, so it is idempotent.
function ensureSheets(ss) {
  TAB_SPECS.forEach(function (spec) {
    if (ss.getSheetByName(spec.name)) return;
    var sheet = ss.insertSheet(spec.name);
    sheet.getRange(1, 1, 1, spec.cols.length).setValues([spec.cols]);
    sheet.setFrozenRows(1);
    spec.textCols.forEach(function (col) {
      sheet.getRange(1, col, sheet.getMaxRows() || 1000, 1).setNumberFormat("@");
    });
    if (spec.name === TAB_SETTINGS) {
      var rows = DEFAULT_SETTINGS.map(function (s) { return [s.key, s.value, s.note]; });
      ensureRows(sheet, rows.length + 1);
      sheet.getRange(2, 1, rows.length, 3).setValues(rows);
    }
    if (spec.hidden) sheet.hideSheet();
  });
}

// A Date cell (Sheets converts "2026-11-16" text) or a string becomes "yyyy-MM-dd"; anything else "".
function cellToDateString(v, tz) {
  if (v instanceof Date || Object.prototype.toString.call(v) === "[object Date]") {
    return isNaN(v.getTime()) ? "" : localDateString(v.getTime(), tz);
  }
  if (typeof v === "string") return v.trim();
  return "";
}

// Epoch milliseconds from a Date cell or an ISO string; 0 when unreadable.
function cellToMs(v) {
  if (v instanceof Date || Object.prototype.toString.call(v) === "[object Date]") {
    var t = v.getTime();
    return isNaN(t) ? 0 : t;
  }
  if (typeof v === "string") {
    var p = Date.parse(v.trim());
    return isNaN(p) ? 0 : p;
  }
  return 0;
}

function msToIso(ms) {
  return new Date(ms).toISOString();
}

function parseSettingNumber(v, fallback) {
  var s = typeof v === "string" ? v.trim() : v;
  if (typeof s === "string" && s.charAt(s.length - 1) === "%") s = s.slice(0, -1).trim();
  if (s === "" || s === null || s === undefined || typeof s === "boolean") return fallback;
  var n = Number(s);
  return isFinite(n) && n >= 0 ? n : fallback;
}

function parsePlanOrder(v, fallback) {
  if (typeof v !== "string") return fallback;
  var parts = v.split(",").map(function (p) { return p.trim(); }).filter(function (p) { return p !== ""; });
  return parts.length ? parts : fallback;
}

// rows: [[key, value, note?], ...]. Only known keys are read; bad values fall back to defaults.
function parseSettings(rows) {
  var given = new Map();
  (rows || []).forEach(function (r) {
    if (typeof r[0] === "string") given.set(r[0].trim(), r[1]);
  });
  var out = {};
  DEFAULT_SETTINGS.forEach(function (d) {
    var has = given.has(d.key);
    var v = has ? given.get(d.key) : undefined;
    if (typeof d.value === "number") {
      out[d.key] = has ? parseSettingNumber(v, d.value) : d.value;
    } else {
      var fallback = parsePlanOrder(d.value, []);
      out[d.key] = has ? parsePlanOrder(v, fallback) : fallback;
    }
  });
  return out;
}

// A real sheet throws when a range lies past getMaxRows(); grow it first.
function ensureRows(sheet, lastRowNeeded) {
  var max = sheet.getMaxRows();
  if (lastRowNeeded > max) sheet.insertRowsAfter(max, lastRowNeeded - max);
}

// Sheets parses a string written through setValues like typed input: "=1+1" becomes a formula and
// "+18.0%" a number. A leading apostrophe stores the value as text and is not shown. Every free-text
// value written to a sheet goes through this; numbers and other types pass unchanged.
function asText(v) {
  if (typeof v === "string" && v.length > 0 && "=+-@".indexOf(v.charAt(0)) !== -1) return "'" + v;
  return v;
}

function asTextRows(rows) {
  return rows.map(function (r) { return r.map(asText); });
}

// Like sheetRows but reads only the given column spans ([[firstCol, count], ...], 1-based); the other
// cells of each returned row stay "".
function sheetColumns(sheet, spans) {
  var last = sheet.getLastRow();
  if (last < 2) return [];
  var width = 0;
  spans.forEach(function (sp) { width = Math.max(width, sp[0] - 1 + sp[1]); });
  var out = [];
  for (var i = 0; i < last - 1; i++) {
    var row = [];
    for (var c = 0; c < width; c++) row.push("");
    out.push(row);
  }
  spans.forEach(function (sp) {
    var vals = sheet.getRange(2, sp[0], last - 1, sp[1]).getValues();
    for (var r = 0; r < vals.length; r++) {
      for (var k = 0; k < sp[1]; k++) out[r][sp[0] - 1 + k] = vals[r][k];
    }
  });
  return out;
}

function sheetRows(sheet, width) {
  var last = sheet.getLastRow();
  if (last < 2) return [];
  return sheet.getRange(2, 1, last - 1, width).getValues();
}

function cellsEqual(a, b) {
  if (a === b) return true;
  var aDate = a instanceof Date || Object.prototype.toString.call(a) === "[object Date]";
  var bDate = b instanceof Date || Object.prototype.toString.call(b) === "[object Date]";
  return aDate && bDate && a.getTime() === b.getTime();
}

// ignore: 0-based columns left out of the comparison (a received-at stamp must not make a resend "changed").
function rowsEqual(a, b, ignore) {
  if (a.length !== b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (ignore && ignore.indexOf(i) !== -1) continue;
    if (!cellsEqual(a[i], b[i])) return false;
  }
  return true;
}

// Appends columns readWidth+1..width to the rows at the given indexes, one read per run of consecutive
// rows, so a partly read tab (key columns only) can still be compared on the rows a report touches.
function completeRows(sheet, rows, indexes, readWidth, width) {
  var sorted = indexes.slice().sort(function (a, b) { return a - b; });
  var k = 0;
  while (k < sorted.length) {
    var end = k;
    while (end + 1 < sorted.length && sorted[end + 1] === sorted[end] + 1) end++;
    var vals = sheet.getRange(sorted[k] + 2, readWidth + 1, end - k + 1, width - readWidth).getValues();
    for (var j = 0; j <= end - k; j++) rows[sorted[k + j]] = rows[sorted[k + j]].concat(vals[j]);
    k = end + 1;
  }
}

// Writes the changed rows and appends the new ones. dirty: indexes of rows whose built value differs
// from what was read. spans ([[firstCol, count], ...], 1-based) limits an in-place rewrite to the
// columns the script owns, so an owner's edit to another column of the row is never overwritten.
function flushRows(sheet, width, rows, existingCount, dirty, spans) {
  dirty.forEach(function (i) {
    (spans || [[1, width]]).forEach(function (span) {
      var part = rows[i].slice(span[0] - 1, span[0] - 1 + span[1]);
      sheet.getRange(i + 2, span[0], 1, span[1]).setValues(asTextRows([part]));
    });
  });
  if (rows.length > existingCount) {
    var added = rows.slice(existingCount);
    ensureRows(sheet, existingCount + 1 + added.length);
    sheet.getRange(existingCount + 2, 1, added.length, width).setValues(asTextRows(added));
  }
}

// items: [{ key, build(oldRow | null) -> newRow }]. Existing rows are rewritten in place (one
// setValues per row, skipped when build returns an equal row), new rows appended in one block. A
// repeated key within items updates the same row.
//   opts.readWidth: read only the first N columns (the key columns). The rows the items hit are then
//     completed to the full width (completeRows) so they can be compared. Defaults to width.
//   opts.ignoreCols: 0-based columns left out of the "unchanged" comparison.
//   opts.spans: see flushRows.
//   opts.refuse(newCount, existingCount): a reason string stops the call before anything is written.
// Returns { added: new rows appended, refused: reason or null }.
function upsertRows(sheet, width, keyOfRow, items, opts) {
  var o = opts || {};
  var readWidth = o.readWidth || width;
  var rows = sheetRows(sheet, readWidth);
  var index = new Map();
  rows.forEach(function (r, i) { index.set(keyOfRow(r), i); });
  var existingCount = rows.length;
  if (readWidth < width) {
    var hit = new Set();
    items.forEach(function (item) { if (index.has(item.key)) hit.add(index.get(item.key)); });
    completeRows(sheet, rows, Array.from(hit), readWidth, width);
  }
  var dirty = new Set();
  items.forEach(function (item) {
    var i = index.get(item.key);
    if (i === undefined) {
      rows.push(item.build(null));
      index.set(item.key, rows.length - 1);
    } else {
      var built = item.build(rows[i]);
      if (i < existingCount && !rowsEqual(built, rows[i], o.ignoreCols)) dirty.add(i);
      rows[i] = built;
    }
  });
  var refused = o.refuse ? o.refuse(rows.length - existingCount, existingCount) : null;
  if (refused) return { added: 0, refused: refused };
  flushRows(sheet, width, rows, existingCount, dirty, o.spans);
  return { added: rows.length - existingCount, refused: null };
}

function sha256Hex(text) {
  var bytes = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, text, Utilities.Charset.UTF_8);
  return bytes.map(function (b) { return ("0" + (b & 0xff).toString(16)).slice(-2); }).join("");
}

// Returns "ok" when the member may write (first sight or a matching secret), "device_mismatch" for a
// known member with another secret, and "sheet_full" / "rate_limited" when a first sight would pass the
// member caps. budget counts what this clock hour already took in (see readBudget).
function checkDevice(sheet, member, nowMs, budget) {
  var hash = sha256Hex(member.secret);
  var rows = sheetRows(sheet, COLS_DEVICES.length);
  for (var i = 0; i < rows.length; i++) {
    if (rows[i][0] === member.id) {
      if (rows[i][1] !== hash) return "device_mismatch";
      sheet.getRange(i + 2, 4).setValue(msToIso(nowMs));
      return "ok";
    }
  }
  if (rows.length >= MAX_MEMBERS_TOTAL) return "sheet_full";
  if (budget.members >= MAX_NEW_MEMBERS_PER_HOUR) return "rate_limited";
  ensureRows(sheet, rows.length + 2);
  sheet.getRange(rows.length + 2, 1, 1, 4).setValues([[member.id, hash, msToIso(nowMs), msToIso(nowMs)]]);
  budget.members++;
  return "ok";
}

// What this clock hour has taken in so far, kept in the document properties (the script lock is held, so
// there is no race). A new hour starts from zero.
function readBudget(nowMs) {
  var hour = Math.floor(nowMs / 3600000);
  var b = null;
  try { b = JSON.parse(PropertiesService.getDocumentProperties().getProperty(INTAKE_PROP)); } catch (e) { b = null; }
  if (!b || b.hour !== hour) b = { hour: hour, members: 0, raw: 0, limits: 0 };
  return b;
}

function saveBudget(budget) {
  PropertiesService.getDocumentProperties().setProperty(INTAKE_PROP, JSON.stringify(budget));
}

// The refuse callback for one tab: over the total cap is "sheet_full", over this hour's cap "rate_limited".
function refuseOver(hourlyLeft, total) {
  return function (newCount, existingCount) {
    if (newCount === 0) return null;
    if (existingCount + newCount > total) return "sheet_full";
    if (newCount > hourlyLeft) return "rate_limited";
    return null;
  };
}

// The index k in 0..count-1 whose reset time (resetsAtOf(k), epoch ms) is nearest to resetsMs and within
// 24 hours of it, or -1. Weekly windows are 7 days apart and the source jitters by seconds, so this is the
// "same weekly window" test; the store and the plan both use it.
function nearestWindow(count, resetsAtOf, resetsMs) {
  var match = -1, best = Infinity;
  for (var k = 0; k < count; k++) {
    var gap = Math.abs(resetsAtOf(k) - resetsMs);
    if (gap <= DAY_MS && gap < best) { match = k; best = gap; }
  }
  return match;
}

// A limit row is identified by memberId|account|tool plus its weekly window, so a poster can only touch
// rows carrying its own (device-checked) memberId. The same window is the existing row whose reset time
// lies within 24 hours of the incoming one: windows are 7 days apart and the source jitters by seconds.
function upsertLimits(sheet, member, limits, budget) {
  var width = COLS_LIMITS.length;
  var rows = sheetRows(sheet, width);
  var byIdentity = new Map();   // memberId|account|tool -> [row index]
  function identity(memberId, account, tool) { return memberId + "|" + account + "|" + tool; }
  rows.forEach(function (r, i) {
    var k = identity(r[3], r[0], r[1]);
    if (!byIdentity.has(k)) byIdentity.set(k, []);
    byIdentity.get(k).push(i);
  });
  var existingCount = rows.length;
  var dirty = new Set();
  limits.forEach(function (l) {
    var resetsMs = Date.parse(l.resetsAt);
    var readMs = Date.parse(l.readAt);
    var k = identity(member.id, l.account, l.tool);
    var candidates = byIdentity.get(k) || [];
    var at = nearestWindow(candidates.length, function (j) { return cellToMs(rows[candidates[j]][2]); }, resetsMs);
    var match = at === -1 ? -1 : candidates[at];
    if (match === -1) {
      rows.push([l.account, l.tool, msToIso(resetsMs), member.id, l.team, l.plan, l.domain,
        l.usedPercent, l.usedPercent, msToIso(readMs)]);
      if (!byIdentity.has(k)) byIdentity.set(k, []);
      byIdentity.get(k).push(rows.length - 1);
      return;
    }
    var old = rows[match];
    var row = old.slice();
    row[7] = Math.max(Number(old[7]) || 0, l.usedPercent);
    if (readMs >= cellToMs(old[9])) {
      row[2] = msToIso(resetsMs);
      row[4] = l.team; row[5] = l.plan; row[6] = l.domain;
      row[8] = l.usedPercent; row[9] = msToIso(readMs);
    }
    if (match < existingCount && !rowsEqual(row, old)) dirty.add(match);
    rows[match] = row;
  });
  var refused = refuseOver(MAX_NEW_LIMIT_ROWS_PER_HOUR - budget.limits, MAX_LIMIT_ROWS_TOTAL)(rows.length - existingCount, existingCount);
  if (refused) return { added: 0, refused: refused };
  flushRows(sheet, width, rows, existingCount, dirty, null);
  return { added: rows.length - existingCount, refused: null };
}

function writeReport(ss, p, nowMs, tz, budget) {
  var now = msToIso(nowMs);
  var member = p.member;

  var rawItems = [];
  var teamLabelFor = new Map();
  p.days.forEach(function (d) {
    d.tools.forEach(function (t) {
      rawItems.push({
        key: member.id + "|" + d.date + "|" + t.tool,
        build: function () {
          return [member.id, member.nickname, d.date, t.tool, d.team, t.input, t.output, t.cacheWrite, t.cacheRead,
            t.input + t.output + t.cacheWrite + t.cacheRead, member.appVersion, member.platform, now];
        }
      });
    });
    if (!teamLabelFor.has(d.team)) teamLabelFor.set(d.team, "");
    if (d.teamLabel && !teamLabelFor.get(d.team)) teamLabelFor.set(d.team, d.teamLabel);
  });
  p.limits.forEach(function (l) { if (!teamLabelFor.has(l.team)) teamLabelFor.set(l.team, ""); });

  // Only the key columns (A:D) are read for the whole tab; the rows a report hits are completed so an
  // unchanged resend writes nothing (받은시각, the last column, does not count as a change).
  var raw = upsertRows(ss.getSheetByName(TAB_RAW), COLS_RAW.length, function (r) {
    return r[0] + "|" + cellToDateString(r[2], tz) + "|" + r[3];
  }, rawItems, { readWidth: 4, ignoreCols: [COLS_RAW.length - 1],
    refuse: refuseOver(MAX_NEW_RAW_ROWS_PER_HOUR - budget.raw, MAX_RAW_ROWS_TOTAL) });
  if (raw.refused) return { ok: false, error: raw.refused };
  budget.raw += raw.added;

  var lim = upsertLimits(ss.getSheetByName(TAB_LIMITS), member, p.limits, budget);
  if (lim.refused) return { ok: false, error: lim.refused };
  budget.limits += lim.added;

  // 합칠대상 (D) belongs to the owner: a report writes B:C and E:F only.
  upsertRows(ss.getSheetByName(TAB_PEOPLE), COLS_PEOPLE.length, function (r) { return r[0]; }, [{
    key: member.id,
    build: function (old) {
      return [member.id, member.nickname, now, old === null ? "" : old[3], member.appVersion, member.platform];
    }
  }], { spans: [[2, 2], [5, 2]] });

  var deptItems = [];
  teamLabelFor.forEach(function (label, team) {
    deptItems.push({
      key: team,
      build: function (old) { return old === null ? [team, "", label, localDateString(nowMs, tz)] : old; }
    });
  });
  upsertRows(ss.getSheetByName(TAB_DEPTS), COLS_DEPTS.length, function (r) { return r[0]; }, deptItems);

  var labelItems = [];
  var seen = new Set();
  p.days.forEach(function (d) {
    if (!d.teamLabel || seen.has(d.team)) return;
    seen.add(d.team);
    labelItems.push({
      key: d.team + "|" + member.id,
      build: function () { return [d.team, member.id, d.teamLabel, now]; }
    });
  });
  upsertRows(ss.getSheetByName(TAB_TEAMLABELS), COLS_TEAMLABELS.length, function (r) { return r[0] + "|" + r[1]; }, labelItems);

  return { ok: true, accepted: { days: rawItems.length, limits: p.limits.length }, dropped: p.dropped };
}

function handleReport(ss, text, nowMs, tz) {
  // Parsing needs no sheet, so it runs before the lock is taken.
  var p = parsePayload(text, nowMs, tz);
  if (!p.ok) return { ok: false, error: p.error };
  var lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    ensureSheets(ss);
    var budget = readBudget(nowMs);
    try {
      var device = checkDevice(ss.getSheetByName(TAB_DEVICES), p.member, nowMs, budget);
      if (device !== "ok") return { ok: false, error: device };
      return writeReport(ss, p, nowMs, tz, budget);
    } finally {
      saveBudget(budget);
    }
  } finally {
    lock.releaseLock();
  }
}

// Normalized view of every data tab for the dashboards and the plan.
function readAll(ss, tz) {
  function rowsOf(name, cols, spans) {
    var sheet = ss.getSheetByName(name);
    if (!sheet) return [];
    return spans ? sheetColumns(sheet, spans) : sheetRows(sheet, cols.length);
  }
  // Only the columns the dashboards use: memberId..팀ID (A:E) and 합계 (J).
  var usage = rowsOf(TAB_RAW, COLS_RAW, [[1, 5], [10, 1]]).map(function (r) {
    return { memberId: r[0], date: cellToDateString(r[2], tz), tool: r[3], team: r[4], total: Number(r[9]) || 0 };
  });
  var limits = rowsOf(TAB_LIMITS, COLS_LIMITS).map(function (r) {
    return {
      account: r[0], tool: r[1], resetsAt: cellToMs(r[2]), memberId: r[3], team: r[4], plan: r[5], domain: r[6],
      maxUsed: Number(r[7]) || 0, lastUsed: Number(r[8]) || 0, lastReadAt: cellToMs(r[9])
    };
  });
  var people = Object.create(null);
  rowsOf(TAB_PEOPLE, COLS_PEOPLE).forEach(function (r) {
    people[r[0]] = { nickname: String(r[1]), mergeInto: String(r[3] === undefined ? "" : r[3]).trim() };
  });
  var depts = Object.create(null);
  rowsOf(TAB_DEPTS, COLS_DEPTS).forEach(function (r) {
    depts[r[0]] = { name: String(r[1]).trim(), suggested: String(r[2]) };
  });
  var teamLabels = rowsOf(TAB_TEAMLABELS, COLS_TEAMLABELS).map(function (r) {
    return { team: r[0], memberId: r[1], label: String(r[2]) };
  });
  var settings = parseSettings(rowsOf(TAB_SETTINGS, COLS_SETTINGS));
  return { usage: usage, limits: limits, people: people, depts: depts, teamLabels: teamLabels, settings: settings,
    enterprise: readEnterprise(ss, tz) };
}
