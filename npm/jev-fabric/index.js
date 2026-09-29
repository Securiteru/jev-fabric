"use strict";
// Locates the prebuilt native executable installed through this package's
// optional per-platform dependency. No install scripts, no downloads: npm (or
// bun, pnpm, yarn) installs only the package whose os/cpu/libc match the host.
const fs = require("node:fs");
const path = require("node:path");

const PLATFORM_PACKAGES = {
  "darwin-arm64": "jev-fabric-darwin",
  "darwin-x64": "jev-fabric-darwin",
  "linux-x64": "jev-fabric-linux-x64",
  "linux-arm64": "jev-fabric-linux-arm64",
};

/** The platform package name for this host, or undefined if none is published. */
function platformPackage(platform = process.platform, arch = process.arch) {
  return PLATFORM_PACKAGES[`${platform}-${arch}`];
}

/** Absolute path of the installed native executable, or undefined. */
function binaryPath() {
  const name = platformPackage();
  if (!name) return undefined;
  let directory;
  try {
    directory = path.dirname(require.resolve(`${name}/package.json`));
  } catch {
    return undefined;
  }
  const binary = path.join(directory, "bin", "jev-fabric");
  return fs.existsSync(binary) ? binary : undefined;
}

// Plain assignments so Node's CommonJS lexer exposes named ESM imports.
exports.version = require("./package.json").version;
exports.platformPackage = platformPackage;
exports.binaryPath = binaryPath;
/** Single-file `serve` clients: python/jev_fabric.py and typescript/jev-fabric.ts. */
exports.clientsDirectory = path.join(__dirname, "clients");
