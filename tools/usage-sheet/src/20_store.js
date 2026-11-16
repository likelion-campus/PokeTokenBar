// Sheet storage: tab setup, upserts, the device check and the readers. Key lookups use Map
// (or null-prototype objects) because keys come from outside.

var TAB_SPECS = [
  { name: TAB_RAW, cols: COLS_RAW, dateCols: [3] },
  { name: TAB_LIMITS, cols: COLS_LIMITS, dateCols: [3, 10] },
  { name: TAB_PEOPLE, cols: COLS_PEOPLE, dateCols: [] },
  { name: TAB_DEPTS, cols: COLS_DEPTS, dateCols: [4] },
  { name: TAB_TEAMLABELS, cols: COLS_TEAMLABELS, dateCols: [], hidden: true },
  { name: TAB_DEVICES, cols: COLS_DEVICES, dateCols: [], hidden: true },
  { name: TAB_SETTINGS, cols: COLS_SETTINGS, dateCols: [] }
];

// Creates every missing data tab. Existing tabs are left alone, so it is idempotent.
function ensureSheets(ss) {
  TAB_SPECS.forEach(function (spec) {
    if (ss.getSheetByName(spec.name)) return;
    var sheet = ss.insertSheet(spec.name);
    sheet.getRange(1, 1, 1, spec.cols.length).setValues([spec.cols]);
    sheet.setFrozenRows(1);
    spec.dateCols.forEach(function (col) {
      sheet.getRange(1, col, sheet.getMaxRows() || 1000, 1).setNumberFormat("@");
    });
    if (spec.name === TAB_SETTINGS) {
      var rows = DEFAULT_SETTINGS.map(function (s) { return [s.key, s.value, s.note]; });
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

function sheetRows(sheet, width) {
  var last = sheet.getLastRow();
  if (last < 2) return [];
  return sheet.getRange(2, 1, last - 1, width).getValues();
}

// items: [{ key, build(oldRow | null) -> newRow }]. Existing rows are rewritten in place (one
// setValues per row), new rows appended in one block. A repeated key within items updates the same row.
function upsertRows(sheet, width, keyOfRow, items) {
  var rows = sheetRows(sheet, width);
  var index = new Map();
  rows.forEach(function (r, i) { index.set(keyOfRow(r), i); });
  var existingCount = rows.length;
  var dirty = new Set();
  items.forEach(function (item) {
    var i = index.get(item.key);
    if (i === undefined) {
      rows.push(item.build(null));
      index.set(item.key, rows.length - 1);
    } else {
      rows[i] = item.build(rows[i]);
      if (i < existingCount) dirty.add(i);
    }
  });
  dirty.forEach(function (i) {
    sheet.getRange(i + 2, 1, 1, width).setValues([rows[i]]);
  });
  if (rows.length > existingCount) {
    var added = rows.slice(existingCount);
    sheet.getRange(existingCount + 2, 1, added.length, width).setValues(added);
  }
}

function sha256Hex(text) {
  var bytes = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, text, Utilities.Charset.UTF_8);
  return bytes.map(function (b) { return ("0" + (b & 0xff).toString(16)).slice(-2); }).join("");
}

// Returns true when the member may write (first sight or a matching secret).
function checkDevice(sheet, member, nowMs) {
  var hash = sha256Hex(member.secret);
  var rows = sheetRows(sheet, COLS_DEVICES.length);
  for (var i = 0; i < rows.length; i++) {
    if (rows[i][0] === member.id) {
      if (rows[i][1] !== hash) return false;
      sheet.getRange(i + 2, 4).setValue(msToIso(nowMs));
      return true;
    }
  }
  sheet.getRange(rows.length + 2, 1, 1, 4).setValues([[member.id, hash, msToIso(nowMs), msToIso(nowMs)]]);
  return true;
}

function writeReport(ss, p, nowMs, tz) {
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

  upsertRows(ss.getSheetByName(TAB_RAW), COLS_RAW.length, function (r) {
    return r[0] + "|" + cellToDateString(r[2], tz) + "|" + r[3];
  }, rawItems);

  var limitItems = p.limits.map(function (l) {
    var resetsMs = Date.parse(l.resetsAt);
    var readMs = Date.parse(l.readAt);
    return {
      key: l.account + "|" + l.tool + "|" + msToIso(resetsMs),
      build: function (old) {
        if (old === null) {
          return [l.account, l.tool, msToIso(resetsMs), member.id, l.team, l.plan, l.domain,
            l.usedPercent, l.usedPercent, msToIso(readMs)];
        }
        var row = old.slice();
        row[7] = Math.max(Number(old[7]) || 0, l.usedPercent);
        if (readMs >= cellToMs(old[9])) {
          row[2] = msToIso(resetsMs);
          row[3] = member.id; row[4] = l.team; row[5] = l.plan; row[6] = l.domain;
          row[8] = l.usedPercent; row[9] = msToIso(readMs);
        }
        return row;
      }
    };
  });
  upsertRows(ss.getSheetByName(TAB_LIMITS), COLS_LIMITS.length, function (r) {
    return r[0] + "|" + r[1] + "|" + msToIso(cellToMs(r[2]));
  }, limitItems);

  upsertRows(ss.getSheetByName(TAB_PEOPLE), COLS_PEOPLE.length, function (r) { return r[0]; }, [{
    key: member.id,
    build: function (old) {
      return [member.id, member.nickname, now, old === null ? "" : old[3], member.appVersion, member.platform];
    }
  }]);

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

  return { ok: true, accepted: { days: rawItems.length, limits: limitItems.length }, dropped: p.dropped };
}

function handleReport(ss, text, nowMs, tz) {
  var lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    ensureSheets(ss);
    var p = parsePayload(text, nowMs, tz);
    if (!p.ok) return { ok: false, error: p.error };
    if (!checkDevice(ss.getSheetByName(TAB_DEVICES), p.member, nowMs)) return { ok: false, error: "device_mismatch" };
    return writeReport(ss, p, nowMs, tz);
  } finally {
    lock.releaseLock();
  }
}

// Normalized view of every data tab for the dashboards and the plan.
function readAll(ss, tz) {
  function rowsOf(name, cols) {
    var sheet = ss.getSheetByName(name);
    return sheet ? sheetRows(sheet, cols.length) : [];
  }
  var usage = rowsOf(TAB_RAW, COLS_RAW).map(function (r) {
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
  return { usage: usage, limits: limits, people: people, depts: depts, teamLabels: teamLabels, settings: settings };
}
