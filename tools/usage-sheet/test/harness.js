"use strict";
// Loads the concatenated script into a vm context with in-memory fakes of the
// Apps Script services. The code under test is byte-identical to dist/Code.gs.
const vm = require("node:vm");
const { buildSource } = require("../build.js");

const DEFAULT_NOW_MS = Date.parse("2026-11-16T03:00:00Z");
const DEFAULT_TZ = "Asia/Seoul";

function formatInZone(date, tz, pattern) {
  const parts = {};
  new Intl.DateTimeFormat("en-CA", {
    timeZone: tz, hourCycle: "h23",
    year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit",
  }).formatToParts(date).forEach((p) => { parts[p.type] = p.value; });
  if (pattern === "yyyy-MM-dd") return `${parts.year}-${parts.month}-${parts.day}`;
  if (pattern === "yyyy-MM-dd HH:mm") return `${parts.year}-${parts.month}-${parts.day} ${parts.hour}:${parts.minute}`;
  throw new Error(`fake Utilities.formatDate: unsupported pattern ${pattern}`);
}

// Later tasks extend the returned object with more fakes.
function makeFakes(opts) {
  const tz = (opts && opts.tz) || DEFAULT_TZ;
  return {
    Utilities: { formatDate: formatInZone },
    Session: { getScriptTimeZone: () => tz },
  };
}

function loadScript(opts) {
  const o = opts || {};
  const fakes = makeFakes(o);
  const ctx = vm.createContext({ console, Date, Math, JSON, ...fakes });
  vm.runInContext(buildSource(), ctx, { filename: "Code.gs" });
  ctx.fakes = fakes;
  ctx.nowMs = o.nowMs === undefined ? DEFAULT_NOW_MS : o.nowMs;
  ctx.tz = o.tz || DEFAULT_TZ;
  return ctx;
}

module.exports = { loadScript, makeFakes, DEFAULT_NOW_MS, DEFAULT_TZ };
