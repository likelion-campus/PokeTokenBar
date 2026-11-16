"use strict";
// Loads the concatenated script into a vm context with in-memory fakes of the
// Apps Script services. The code under test is byte-identical to dist/Code.gs.
const vm = require("node:vm");
const crypto = require("node:crypto");
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

// Fakes are in-memory and only as wide as the script uses.
//   SpreadsheetApp.getActiveSpreadsheet() -> one fake spreadsheet:
//     getSheetByName, insertSheet, getSheets, deleteSheet
//   Sheet: getName, getLastRow, getLastColumn, getMaxRows, insertRowsAfter, getRange(row, col, numRows?, numCols?) [strict about the 1000-row grid]
//     [getValues/setValues/setValue/setNumberFormat/clearContent], appendRow, hideSheet,
//     isSheetHidden, deleteRow, deleteRows, getCharts/insertChart/removeChart, newChart (recording builder),
//     setFrozenRows, clear. Test-only inspection: sheet._rows, sheet._formats (col -> format).
//   LockService.getScriptLock(): counts acquire (waitLock) and release (releaseLock) in lockStats.
//   Utilities: formatDate, computeDigest (signed bytes like Apps Script), DigestAlgorithm, Charset.
//   ContentService.createTextOutput(text).setMimeType(m); MimeType.JSON.
//   Session.getScriptTimeZone().
// Later tasks extend the returned object with more fakes.
// Like real Sheets, a string written by setValues is parsed as typed input unless the column is
// plain text ("@") or the string starts with an apostrophe (stripped, stored as text).
class FormulaCell { constructor(text) { this.text = text; } }
function coerce(v, textFormat) {
  if (typeof v !== "string") return v;
  if (v.startsWith("'")) return v.slice(1);
  if (textFormat) return v;
  if (v.startsWith("=")) return new FormulaCell(v);
  if (/^[+-]?\d+(\.\d+)?%?$/.test(v)) return v.endsWith("%") ? Number(v.slice(0, -1)) / 100 : Number(v);
  return v;
}

function makeSheet(name) {
  const sheet = {
    _name: name, _rows: [], _hidden: false, _formats: {}, _charts: [], _frozen: 0, _maxRows: 1000,
    getName: () => name,
    getLastRow() {
      for (let i = sheet._rows.length - 1; i >= 0; i--) {
        if (sheet._rows[i].some((v) => v !== "" && v !== null && v !== undefined)) return i + 1;
      }
      return 0;
    },
    getLastColumn() {
      let w = 0;
      sheet._rows.forEach((r) => { for (let i = r.length - 1; i >= 0; i--) { if (r[i] !== "" && r[i] !== undefined) { w = Math.max(w, i + 1); break; } } });
      return w;
    },
    getMaxRows: () => sheet._maxRows,
    insertRowsAfter(after, n) { if (after > sheet._maxRows) throw new Error("fake insertRowsAfter: bad position"); sheet._maxRows += n; },
    getRange(row, col, numRows, numCols) {
      const nr = numRows === undefined ? 1 : numRows;
      const nc = numCols === undefined ? 1 : numCols;
      if (row < 1 || col < 1 || nr < 1 || nc < 1) throw new Error("fake getRange: bad coordinates");
      // Like real Sheets: a range past the grid throws (a new tab has 1000 rows).
      if (row + nr - 1 > sheet._maxRows) throw new Error("fake getRange: coordinates outside the dimensions");
      return {
        _a1: { row, col, numRows: nr, numCols: nc },
        setFontWeight() { return this; },
        getValues() {
          const out = [];
          for (let r = 0; r < nr; r++) {
            const line = [];
            for (let c = 0; c < nc; c++) {
              const v = (sheet._rows[row - 1 + r] || [])[col - 1 + c];
              line.push(v === undefined ? "" : v instanceof FormulaCell ? "#FORMULA" : v);
            }
            out.push(line);
          }
          return out;
        },
        setValues(values) {
          if (values.length !== nr || values.some((l) => l.length !== nc)) throw new Error("fake setValues: size mismatch");
          values.forEach((line, r) => {
            while (sheet._rows.length <= row - 1 + r) sheet._rows.push([]);
            line.forEach((v, c) => { sheet._rows[row - 1 + r][col - 1 + c] = coerce(v, sheet._formats[col + c] === "@"); });
          });
          return this;
        },
        setValue(v) { return this.setValues([[v]]); },
        setFormula(f) {
          if (nr !== 1 || nc !== 1) throw new Error("fake setFormula: single cell only");
          while (sheet._rows.length <= row - 1) sheet._rows.push([]);
          sheet._rows[row - 1][col - 1] = new FormulaCell(f);
          return this;
        },
        getFormula() {
          const v = (sheet._rows[row - 1] || [])[col - 1];
          return v instanceof FormulaCell ? v.text : "";
        },
        setNumberFormat(f) { for (let c = 0; c < nc; c++) sheet._formats[col + c] = f; return this; },
        clearContent() {
          for (let r = 0; r < nr; r++) for (let c = 0; c < nc; c++) {
            if (sheet._rows[row - 1 + r]) sheet._rows[row - 1 + r][col - 1 + c] = "";
          }
        },
      };
    },
    appendRow(values) { sheet._rows.push(values.slice()); },
    hideSheet() { sheet._hidden = true; },
    isSheetHidden: () => sheet._hidden,
    deleteRow(n) { sheet._rows.splice(n - 1, 1); },
    deleteRows(n, count) { sheet._rows.splice(n - 1, count); },
    getCharts: () => sheet._charts.slice(),
    insertChart(c) { sheet._charts.push(c); },
    removeChart(c) { sheet._charts = sheet._charts.filter((x) => x !== c); },
    newChart() {
      const calls = [];
      const b = new Proxy({}, { get: (_, k) => (k === "build" ? () => ({ calls }) : (...a) => { calls.push([k, ...a]); return b; }) });
      return b;
    },
    setFrozenRows(n) { sheet._frozen = n; },
    clear() { sheet._rows = []; sheet._formats = {}; },
  };
  return sheet;
}

function makeFakes(opts) {
  const tz = (opts && opts.tz) || DEFAULT_TZ;
  const sheets = [];
  const ss = {
    _sheets: sheets,
    getSheetByName: (n) => sheets.find((s) => s.getName() === n) || null,
    insertSheet(n) { const s = makeSheet(n); sheets.push(s); return s; },
    getSheets: () => sheets.slice(),
    deleteSheet(s) { sheets.splice(sheets.indexOf(s), 1); },
  };
  const lockStats = { acquired: 0, released: 0 };
  return {
    ss,
    lockStats,
    SpreadsheetApp: { getActiveSpreadsheet: () => ss },
    LockService: {
      getScriptLock: () => ({
        waitLock() { lockStats.acquired++; },
        releaseLock() { lockStats.released++; },
      }),
    },
    Utilities: {
      formatDate: formatInZone,
      DigestAlgorithm: { SHA_256: "SHA_256" },
      Charset: { UTF_8: "UTF_8" },
      computeDigest(alg, value) {
        if (alg !== "SHA_256") throw new Error("fake computeDigest: unsupported algorithm");
        return Array.from(crypto.createHash("sha256").update(value, "utf8").digest()).map((b) => (b > 127 ? b - 256 : b));
      },
    },
    ContentService: {
      MimeType: { JSON: "JSON", TEXT: "TEXT" },
      createTextOutput(text) {
        const out = { _text: text, _mime: "TEXT", getContent: () => out._text, getMimeType: () => out._mime,
          setMimeType(m) { out._mime = m; return out; } };
        return out;
      },
    },
    Session: { getScriptTimeZone: () => tz },
    Charts: { ChartType: { BAR: "BAR" } },
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
