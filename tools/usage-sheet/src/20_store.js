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
  ensureDeviceColumns(ss.getSheetByName(TAB_DEVICES));
}

// A 기기 tab made before the per-member hourly counters has 4 columns (setup trimmed it); widen it and
// add the headers. One cell read when nothing is missing.
function ensureDeviceColumns(sheet) {
  var need = COLS_DEVICES.length;
  var max = sheet.getMaxColumns();
  if (max < need) sheet.insertColumnsAfter(max, need - max);
  if (sheet.getRange(1, need).getValues()[0][0] !== COLS_DEVICES[need - 1]) {
    sheet.getRange(1, 1, 1, need).setValues([COLS_DEVICES]);
  }
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
// from what was read. Each run of adjacent changed rows is one setValues call per span, so a report
// holds the script lock for as many calls as it has runs, not rows. spans ([[firstCol, count], ...],
// 1-based) limits an in-place rewrite to the columns the script owns, so an owner's edit to another
// column of the row is never overwritten.
function flushRows(sheet, width, rows, existingCount, dirty, spans) {
  var sorted = Array.from(dirty).sort(function (a, b) { return a - b; });
  var k = 0;
  while (k < sorted.length) {
    var end = k;
    while (end + 1 < sorted.length && sorted[end + 1] === sorted[end] + 1) end++;
    (spans || [[1, width]]).forEach(function (span) {
      var part = [];
      for (var j = k; j <= end; j++) part.push(rows[sorted[j]].slice(span[0] - 1, span[0] - 1 + span[1]));
      sheet.getRange(sorted[k] + 2, span[0], part.length, span[1]).setValues(asTextRows(part));
    });
    k = end + 1;
  }
  if (rows.length > existingCount) {
    var added = rows.slice(existingCount);
    ensureRows(sheet, existingCount + 1 + added.length);
    sheet.getRange(existingCount + 2, 1, added.length, width).setValues(asTextRows(added));
  }
}

// items: [{ key, build(oldRow | null) -> newRow }]. planRows reads and builds without writing; applyPlan
// writes. Existing rows are rewritten in place (skipped when build returns an equal row), new rows
// appended in one block. A repeated key within items updates the same row.
//   opts.readWidth: read only the first N columns (the key columns). The rows the items hit are then
//     completed to the full width (completeRows) so they can be compared. Defaults to width.
//   opts.ignoreCols: 0-based columns left out of the "unchanged" comparison.
//   opts.normalizeOld(row) -> row: the old row as it is compared (Sheets may have turned text into a Date or number).
//   opts.spans: see flushRows.
// Returns { sheet, width, rows, existingCount, dirty, spans, added: new rows to append }.
function planRows(sheet, width, keyOfRow, items, opts) {
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
      var oldRow = o.normalizeOld ? o.normalizeOld(rows[i]) : rows[i];
      if (i < existingCount && !rowsEqual(built, oldRow, o.ignoreCols)) dirty.add(i);
      rows[i] = built;
    }
  });
  return { sheet: sheet, width: width, rows: rows, existingCount: existingCount, dirty: dirty, spans: o.spans || null,
    added: rows.length - existingCount };
}

function applyPlan(plan) {
  flushRows(plan.sheet, plan.width, plan.rows, plan.existingCount, plan.dirty, plan.spans);
}

// Plan and write in one call, for tabs with no cap (the Enterprise tabs).
function upsertRows(sheet, width, keyOfRow, items, opts) {
  var plan = planRows(sheet, width, keyOfRow, items, opts);
  applyPlan(plan);
  return { added: plan.added };
}

function sha256Hex(text) {
  var bytes = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, text, Utilities.Charset.UTF_8);
  return bytes.map(function (b) { return ("0" + (b & 0xff).toString(16)).slice(-2); }).join("");
}

// Looks the member up in 기기 without writing. status is "ok" (first sight or a matching secret),
// "device_mismatch" for a known member with another secret, or "sheet_full" / "rate_limited" when a first
// sight would pass the member caps. For "ok" it also carries what writeReport needs: the row to write
// (rowNum), whether the member is new or first seen in this clock hour (firstThisHour: such members are
// also charged against the shared hourly pool), and what the member already took in this hour. budget
// counts what this clock hour already took in (see readBudget).
function lookupDevice(sheet, member, nowMs, budget) {
  var hash = sha256Hex(member.secret);
  var hour = Math.floor(nowMs / 3600000);
  var rows = sheetRows(sheet, COLS_DEVICES.length);
  for (var i = 0; i < rows.length; i++) {
    if (rows[i][0] !== member.id) continue;
    if (rows[i][1] !== hash) return { status: "device_mismatch" };
    var same = Number(rows[i][4]) === hour;
    return { status: "ok", hash: hash, rowNum: i + 2, isNew: false,
      firstThisHour: Math.floor(cellToMs(rows[i][2]) / 3600000) === hour,
      raw: same ? Number(rows[i][5]) || 0 : 0, limits: same ? Number(rows[i][6]) || 0 : 0,
      teams: same ? Number(rows[i][7]) || 0 : 0 };
  }
  if (rows.length >= MAX_MEMBERS_TOTAL) return { status: "sheet_full" };
  if (budget.members >= MAX_NEW_MEMBERS_PER_HOUR) return { status: "rate_limited" };
  return { status: "ok", hash: hash, rowNum: rows.length + 2, isNew: true, firstThisHour: true, raw: 0, limits: 0, teams: 0 };
}

// Registers a new member or stamps a known one, with the hour's counters after this report.
function writeDevice(sheet, dev, member, nowMs, hour, budget) {
  var now = msToIso(nowMs);
  if (dev.isNew) {
    ensureRows(sheet, dev.rowNum);
    sheet.getRange(dev.rowNum, 1, 1, COLS_DEVICES.length).setValues([[member.id, dev.hash, now, now, hour, dev.raw, dev.limits, dev.teams]]);
    budget.members++;
  } else {
    sheet.getRange(dev.rowNum, 4, 1, COLS_DEVICES.length - 3).setValues([[now, hour, dev.raw, dev.limits, dev.teams]]);
  }
}

// What this clock hour has taken in so far from members first seen in it, kept in the document properties
// (the script lock is held, so there is no race). A new hour starts from zero.
function readBudget(nowMs) {
  var hour = Math.floor(nowMs / 3600000);
  var b = null;
  try { b = JSON.parse(PropertiesService.getDocumentProperties().getProperty(INTAKE_PROP)); } catch (e) { b = null; }
  if (!b || b.hour !== hour) b = { hour: hour, members: 0, raw: 0, limits: 0, teams: 0 };
  if (typeof b.teams !== "number") b.teams = 0;
  return b;
}

function saveBudget(budget) {
  PropertiesService.getDocumentProperties().setProperty(INTAKE_PROP, JSON.stringify(budget));
}

// The reason new rows are refused, or null. Over the tab's total is "sheet_full"; over what the member
// may still add this hour, or over the shared pool left (Infinity when the member is not charged to it),
// is "rate_limited".
function refuseNew(added, existing, total, memberLeft, poolLeft) {
  if (added === 0) return null;
  if (existing + added > total) return "sheet_full";
  if (added > memberLeft || added > poolLeft) return "rate_limited";
  return null;
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
// Reads and builds without writing, like planRows.
function planLimits(sheet, member, limits) {
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
  return { sheet: sheet, width: width, rows: rows, existingCount: existingCount, dirty: dirty, spans: null,
    added: rows.length - existingCount };
}

// Sheets may have turned a stored date text into a Date and a version like "1.2" into a number; compare
// the old row as the text it was written as, so an unchanged row is really skipped.
function normalizeRawRow(tz) {
  return function (r) {
    var c = r.slice();
    c[2] = cellToDateString(r[2], tz);
    if (typeof c[10] === "number") c[10] = String(c[10]);
    return c;
  };
}

// Plans every tab, evaluates every refusal, then writes. A refused raw list refuses the whole report
// (nothing is written, the sender retries). A refused limit list or team list is dropped and the rest
// is accepted: usage must land even while 한도 is full or the member is over its limit share.
function writeReport(ss, p, nowMs, tz, budget, dev) {
  var now = msToIso(nowMs);
  var hour = Math.floor(nowMs / 3600000);
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

  // The pool is charged only for a member first seen in this hour.
  function poolLeft(used, cap) { return dev.firstThisHour ? cap - used : Infinity; }

  // Only the key columns (A:D) are read for the whole tab; the rows a report hits are completed so an
  // unchanged resend writes nothing (받은시각, the last column, does not count as a change).
  var rawPlan = planRows(ss.getSheetByName(TAB_RAW), COLS_RAW.length, function (r) {
    return r[0] + "|" + cellToDateString(r[2], tz) + "|" + r[3];
  }, rawItems, { readWidth: 4, ignoreCols: [COLS_RAW.length - 1], normalizeOld: normalizeRawRow(tz) });
  var rawRefused = refuseNew(rawPlan.added, rawPlan.existingCount, MAX_RAW_ROWS_TOTAL,
    MAX_MEMBER_RAW_ROWS_PER_HOUR - dev.raw, poolLeft(budget.raw, MAX_NEW_RAW_ROWS_PER_HOUR));
  if (rawRefused) return { ok: false, error: rawRefused };

  var limPlan = planLimits(ss.getSheetByName(TAB_LIMITS), member, p.limits);
  var limitsOk = !refuseNew(limPlan.added, limPlan.existingCount, MAX_LIMIT_ROWS_TOTAL,
    MAX_MEMBER_LIMIT_ROWS_PER_HOUR - dev.limits, poolLeft(budget.limits, MAX_NEW_LIMIT_ROWS_PER_HOUR));
  if (limitsOk) p.limits.forEach(function (l) { if (!teamLabelFor.has(l.team)) teamLabelFor.set(l.team, ""); });

  // 합칠대상 (D) belongs to the owner: a report writes B:C and E:F only.
  var peoplePlan = planRows(ss.getSheetByName(TAB_PEOPLE), COLS_PEOPLE.length, function (r) { return r[0]; }, [{
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
  var deptPlan = planRows(ss.getSheetByName(TAB_DEPTS), COLS_DEPTS.length, function (r) { return r[0]; }, deptItems);

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
  var labelPlan = planRows(ss.getSheetByName(TAB_TEAMLABELS), COLS_TEAMLABELS.length,
    function (r) { return r[0] + "|" + r[1]; }, labelItems);
  var teamAdded = deptPlan.added + labelPlan.added;
  var teamsOk = !(refuseNew(deptPlan.added, deptPlan.existingCount, MAX_DEPTS_TOTAL, Infinity, Infinity) ||
    refuseNew(labelPlan.added, labelPlan.existingCount, MAX_TEAMLABELS_TOTAL, Infinity, Infinity) ||
    refuseNew(teamAdded, 0, Infinity, MAX_MEMBER_TEAM_ROWS_PER_HOUR - dev.teams, poolLeft(budget.teams, MAX_NEW_TEAM_ROWS_PER_HOUR)));

  // Nothing is refused from here on: write.
  var limAdded = limitsOk ? limPlan.added : 0;
  var teamWritten = teamsOk ? teamAdded : 0;
  dev.raw += rawPlan.added;
  dev.limits += limAdded;
  dev.teams += teamWritten;
  if (dev.firstThisHour) {
    budget.raw += rawPlan.added;
    budget.limits += limAdded;
    budget.teams += teamWritten;
  }
  writeDevice(ss.getSheetByName(TAB_DEVICES), dev, member, nowMs, hour, budget);
  applyPlan(rawPlan);
  if (limitsOk) applyPlan(limPlan);
  applyPlan(peoplePlan);
  if (teamsOk) {
    applyPlan(deptPlan);
    applyPlan(labelPlan);
  }
  return { ok: true, accepted: { days: rawItems.length, limits: limitsOk ? p.limits.length : 0 },
    dropped: p.dropped + (limitsOk ? 0 : p.limits.length) };
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
    var before = JSON.stringify(budget);
    try {
      var dev = lookupDevice(ss.getSheetByName(TAB_DEVICES), p.member, nowMs, budget);
      if (dev.status !== "ok") return { ok: false, error: dev.status };
      return writeReport(ss, p, nowMs, tz, budget, dev);
    } finally {
      // Only a changed budget is written, and a failed write must not fail an otherwise good request.
      if (JSON.stringify(budget) !== before) {
        try { saveBudget(budget); } catch (e) { console.error("saveBudget failed: " + (e && e.message)); }
      }
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
