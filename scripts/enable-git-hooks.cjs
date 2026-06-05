"use strict";

const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

// Resolve from this script's location — reliable for prepare, just hooks, and any cwd.
const packageRoot = path.resolve(__dirname, "..");
const hooksDirName = ".githooks";
const hooksDir = path.join(packageRoot, hooksDirName);

function run(cmd) {
  return execSync(cmd, { cwd: packageRoot, encoding: "utf8" }).trim();
}

function ensureHooksExecutable() {
  if (!fs.existsSync(hooksDir)) {
    throw new Error(`Missing ${hooksDirName}/ directory`);
  }
  for (const name of fs.readdirSync(hooksDir)) {
    const hookPath = path.join(hooksDir, name);
    if (!fs.statSync(hookPath).isFile()) continue;
    fs.chmodSync(hookPath, 0o755);
  }
}

try {
  run("git rev-parse --git-dir");
  ensureHooksExecutable();
  // Relative path is resolved from the directory that contains .git (works in worktrees).
  run(`git config --local core.hooksPath ${hooksDirName}`);
  const configured = run("git config --local --get core.hooksPath");
  if (configured !== hooksDirName) {
    throw new Error(`core.hooksPath is "${configured}", expected "${hooksDirName}"`);
  }
  console.log(`[prepare] Git hooks enabled (core.hooksPath=${configured})`);
} catch (err) {
  const msg = err && err.message ? err.message : String(err);
  console.error(`[prepare] Failed to enable git hooks (packageRoot=${packageRoot}): ${msg}`);
  console.error(`[prepare] Fix manually: git config --local core.hooksPath ${hooksDirName}`);
  process.exit(1);
}
