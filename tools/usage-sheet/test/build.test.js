"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { buildSource } = require("../build.js");

test("dist/Code.gs is up to date", () => {
  const dist = fs.readFileSync(path.join(__dirname, "..", "dist", "Code.gs"), "utf8");
  assert.ok(dist === buildSource(), "dist/Code.gs is stale: run node tools/usage-sheet/build.js");
});
