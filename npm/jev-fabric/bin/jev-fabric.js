#!/usr/bin/env node
"use strict";
// Thin launcher for `npx jev-fabric …`. Harnesses that embed jev-fabric should
// call require("jev-fabric").binaryPath() and spawn the executable directly.
const { spawnSync } = require("node:child_process");
const { binaryPath, platformPackage } = require("..");

const binary = binaryPath();
if (!binary) {
  const name = platformPackage();
  process.stderr.write(
    `jev-fabric: no prebuilt executable for ${process.platform}-${process.arch}` +
      (name ? ` (optional dependency ${name} is not installed)` : " (macOS and Linux only)") +
      ". See https://github.com/monotykamary/jev-fabric#install-it-yourself\n",
  );
  process.exit(1);
}
const result = spawnSync(binary, process.argv.slice(2), { stdio: "inherit" });
if (result.error) {
  process.stderr.write(`jev-fabric: ${result.error.message}\n`);
  process.exit(1);
}
if (result.signal) process.kill(process.pid, result.signal);
process.exit(result.status ?? 1);
