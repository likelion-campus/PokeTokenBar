// Wire contract v1: validation and normalization of a report. No I/O.

var UUID_RE = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;
var SECRET_RE = /^[A-Za-z0-9_-]{32,128}$/;
var VERSION_RE = /^[0-9A-Za-z.+-]{1,32}$/;
var DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
var TEAM_RE = /^t_[A-Za-z0-9_-]{2,62}$/;
var TOOL_RE = /^[a-z0-9_.-]{1,32}$/;
var ACCOUNT_RE = /^(e|m)_[A-Za-z0-9_-]{2,126}$/;
var DOMAIN_RE = /^[a-z0-9.-]{1,253}$/;
var MAX_COUNT = 1e13;
var DAY_MS = 86400000;

function localDateString(ms, tz) {
  return Utilities.formatDate(new Date(ms), tz, "yyyy-MM-dd");
}

// UTF-8 byte length by code point (TextEncoder may be missing in Apps Script).
function utf8Length(s) {
  var n = 0;
  for (var ch of s) {
    var c = ch.codePointAt(0);
    n += c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4;
  }
  return n;
}

function isPlainObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

// The app counts grapheme clusters (Swift String.count), which JS cannot do without Intl.Segmenter, so the
// script bounds the UTF-8 size instead: trimmed, non-empty, at most 320 bytes, no newline. Returns the
// trimmed value or null.
function normalizeNickname(v) {
  if (typeof v !== "string") return null;
  var t = v.trim();
  if (t.length < 1 || /[\r\n]/.test(t) || utf8Length(t) > 320) return null;
  return t;
}

// Days since the epoch for a "yyyy-MM-dd" string, or null when it is not a real calendar date.
function dateToDayNumber(s) {
  if (typeof s !== "string" || !DATE_RE.test(s)) return null;
  var y = Number(s.slice(0, 4)), m = Number(s.slice(5, 7)), d = Number(s.slice(8, 10));
  var t = new Date(Date.UTC(y, m - 1, d));
  if (t.getUTCFullYear() !== y || t.getUTCMonth() !== m - 1 || t.getUTCDate() !== d) return null;
  return t.getTime() / DAY_MS;
}

function validCount(n) {
  return typeof n === "number" && Number.isSafeInteger(n) && n >= 0 && n <= MAX_COUNT;
}

function parseMember(m) {
  if (!isPlainObject(m)) return null;
  var nickname = normalizeNickname(m.nickname);
  if (typeof m.id !== "string" || !UUID_RE.test(m.id)) return null;
  if (typeof m.secret !== "string" || !SECRET_RE.test(m.secret)) return null;
  if (nickname === null) return null;
  if (typeof m.appVersion !== "string" || !VERSION_RE.test(m.appVersion)) return null;
  if (m.platform !== "mac" && m.platform !== "windows") return null;
  return { id: m.id, secret: m.secret, nickname: nickname, appVersion: m.appVersion, platform: m.platform };
}

function parseTool(t) {
  if (!isPlainObject(t) || typeof t.tool !== "string" || !TOOL_RE.test(t.tool)) return null;
  if (!validCount(t.input) || !validCount(t.output) || !validCount(t.cacheWrite) || !validCount(t.cacheRead)) return null;
  return { tool: t.tool, input: t.input, output: t.output, cacheWrite: t.cacheWrite, cacheRead: t.cacheRead };
}

function parseLimit(l, nowMs) {
  if (!isPlainObject(l)) return null;
  if (typeof l.tool !== "string" || !TOOL_RE.test(l.tool)) return null;
  if (typeof l.account !== "string" || !ACCOUNT_RE.test(l.account)) return null;
  if (typeof l.domain !== "string") return null;
  var domain = l.domain.toLowerCase();
  if (domain !== "" && !DOMAIN_RE.test(domain)) return null;
  if (typeof l.plan !== "string" || Array.from(l.plan).length < 1 || Array.from(l.plan).length > 40) return null;
  if (typeof l.usedPercent !== "number" || !isFinite(l.usedPercent) || l.usedPercent < 0 || l.usedPercent > 1000) return null;
  if (typeof l.team !== "string" || !TEAM_RE.test(l.team)) return null;
  if (typeof l.resetsAt !== "string" || typeof l.readAt !== "string") return null;
  var resetsMs = Date.parse(l.resetsAt);
  var readMs = Date.parse(l.readAt);
  if (isNaN(resetsMs) || isNaN(readMs)) return null;
  if (resetsMs < nowMs - 8 * DAY_MS || resetsMs > nowMs + 8 * DAY_MS) return null;
  if (readMs < nowMs - 8 * DAY_MS || readMs > nowMs + 10 * 60 * 1000) return null;
  // The source jitters resets_at by seconds between reads; snap to the hour so one window stays one row.
  var HOUR_MS = 3600000;
  var resetsAt = new Date(Math.round(resetsMs / HOUR_MS) * HOUR_MS).toISOString();
  return {
    tool: l.tool, account: l.account, domain: domain, plan: l.plan, usedPercent: l.usedPercent,
    resetsAt: resetsAt, readAt: new Date(readMs).toISOString(), team: l.team
  };
}

// Returns { ok: true, member, days, limits, dropped } or { ok: false, error }.
function parsePayload(text, nowMs, tz) {
  if (typeof text !== "string") return { ok: false, error: "bad_json" };
  // A JS string is never longer than its UTF-8 bytes, so this rejects without the byte count.
  if (text.length > MAX_BODY_BYTES || utf8Length(text) > MAX_BODY_BYTES) return { ok: false, error: "too_large" };
  var body;
  try { body = JSON.parse(text); } catch (e) { return { ok: false, error: "bad_json" }; }
  if (!isPlainObject(body)) return { ok: false, error: "bad_json" };
  if (body.v !== 1) return { ok: false, error: "bad_version" };
  if (body.token !== SHARED_TOKEN) return { ok: false, error: "bad_token" };
  var member = parseMember(body.member);
  if (member === null) return { ok: false, error: "bad_member" };

  var rawDays = body.days;
  var rawLimits = body.limits === undefined ? [] : body.limits;
  if (!Array.isArray(rawDays) || !Array.isArray(rawLimits)) return { ok: false, error: "bad_json" };
  if (rawDays.length > MAX_DAYS || rawLimits.length > MAX_LIMITS) return { ok: false, error: "too_many_rows" };
  for (var i = 0; i < rawDays.length; i++) {
    if (isPlainObject(rawDays[i]) && Array.isArray(rawDays[i].tools) && rawDays[i].tools.length > MAX_TOOLS_PER_DAY) {
      return { ok: false, error: "too_many_rows" };
    }
  }

  var today = dateToDayNumber(localDateString(nowMs, tz));
  var dropped = 0;
  var byDate = new Map();
  var dateOrder = [];
  rawDays.forEach(function (d) {
    var dayNumber = isPlainObject(d) ? dateToDayNumber(d.date) : null;
    if (dayNumber === null || dayNumber < today - 400 || dayNumber > today + 1 ||
        typeof d.team !== "string" || !TEAM_RE.test(d.team) || !Array.isArray(d.tools)) {
      dropped++;
      return;
    }
    var tools = [];
    d.tools.forEach(function (t) {
      var parsed = parseTool(t);
      if (parsed === null) dropped++; else tools.push(parsed);
    });
    if (d.tools.length > 0 && tools.length === 0) { dropped++; return; }
    var label = normalizeNickname(d.teamLabel);
    var entry = byDate.get(d.date);
    if (!entry) {
      entry = { date: d.date, team: d.team, teamLabel: "", toolMap: new Map(), toolOrder: [] };
      byDate.set(d.date, entry);
      dateOrder.push(d.date);
    }
    entry.team = d.team;
    entry.teamLabel = label === null ? "" : label;
    tools.forEach(function (t) {
      if (!entry.toolMap.has(t.tool)) entry.toolOrder.push(t.tool);
      entry.toolMap.set(t.tool, t); // a repeated date|tool keeps the last occurrence
    });
  });

  var days = dateOrder.map(function (date) {
    var e = byDate.get(date);
    var tools = e.toolOrder.map(function (name) { return e.toolMap.get(name); });
    if (tools.length === 0) tools = [{ tool: "-", input: 0, output: 0, cacheWrite: 0, cacheRead: 0 }];
    return { date: e.date, team: e.team, teamLabel: e.teamLabel, tools: tools };
  });

  var limits = [];
  rawLimits.forEach(function (l) {
    var parsed = parseLimit(l, nowMs);
    if (parsed === null) dropped++; else limits.push(parsed);
  });

  return { ok: true, member: member, days: days, limits: limits, dropped: dropped };
}
