#!/usr/bin/env node
// Turn release archives into npm packages, without publishing them.
//
//   node scripts/package-npm.mjs <dir-with-release-archives> <out-dir>
//
// Produces one package per platform (the executable only, selected by npm's
// os/cpu/libc fields) and the `jev-fabric` package: a launcher, a binaryPath()
// locator for embedding hosts, and the `serve` clients. Each is packed into
// <out-dir>/*.tgz; publishing is a separate, explicit step.
import { execFileSync } from "node:child_process";
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const [archives, out] = process.argv.slice(2).map((path) => resolve(path));
if (!archives || !out) {
  console.error("usage: node scripts/package-npm.mjs <dir-with-release-archives> <out-dir>");
  process.exit(2);
}

const repository = { type: "git", url: "git+https://github.com/monotykamary/jev-fabric.git" };
const common = { license: "MIT", repository, homepage: "https://github.com/monotykamary/jev-fabric" };
// Archive platform -> npm package and its install constraints.
const platforms = [
  { archive: "darwin-universal", name: "jev-fabric-darwin", os: ["darwin"], cpu: ["arm64", "x64"] },
  { archive: "linux-x64", name: "jev-fabric-linux-x64", os: ["linux"], cpu: ["x64"], libc: ["glibc"] },
  { archive: "linux-arm64", name: "jev-fabric-linux-arm64", os: ["linux"], cpu: ["arm64"], libc: ["glibc"] },
];

const json = (path, value) => writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
const scratch = mkdtempSync(join(tmpdir(), "jev-fabric-npm-"));
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

let version;
try {
  for (const platform of platforms) {
    const archive = join(archives, `jev-fabric-${platform.archive}.tar.gz`);
    if (!existsSync(archive)) throw new Error(`missing release archive: ${archive}`);
    const extracted = join(scratch, platform.archive);
    mkdirSync(extracted);
    execFileSync("tar", ["-xzf", archive, "-C", extracted]);
    const release = join(extracted, "jev-fabric");
    const found = readFileSync(join(release, "VERSION"), "utf8").trim().replace(/^v/, "");
    if (version && found !== version) throw new Error(`archive versions differ: ${version} and ${found}`);
    version = found;

    const pkg = join(scratch, "packages", platform.name);
    mkdirSync(join(pkg, "bin"), { recursive: true });
    cpSync(join(release, "bin", "jev-fabric"), join(pkg, "bin", "jev-fabric"));
    chmodSync(join(pkg, "bin", "jev-fabric"), 0o755);
    cpSync(join(root, "LICENSE"), join(pkg, "LICENSE"));
    writeFileSync(join(pkg, "README.md"), `# ${platform.name}\n\nThe ${platform.archive} executable for [jev-fabric](https://github.com/monotykamary/jev-fabric). Install \`jev-fabric\` instead; npm selects this package automatically.\n`);
    json(join(pkg, "package.json"), {
      name: platform.name,
      version,
      description: `The ${platform.archive} executable for jev-fabric.`,
      ...common,
      os: platform.os,
      cpu: platform.cpu,
      ...(platform.libc ? { libc: platform.libc } : {}),
      files: ["bin/jev-fabric", "README.md", "LICENSE"],
      preferUnplugged: true,
    });
  }

  const main = join(scratch, "packages", "jev-fabric");
  cpSync(join(root, "npm", "jev-fabric"), main, { recursive: true });
  // The clients and skill are identical in every archive; take them from the first.
  const release = join(scratch, platforms[0].archive, "jev-fabric");
  cpSync(join(release, "clients"), join(main, "clients"), { recursive: true });
  cpSync(join(release, "skills"), join(main, "skills"), { recursive: true });
  cpSync(join(root, "README.md"), join(main, "README.md"));
  cpSync(join(root, "LICENSE"), join(main, "LICENSE"));
  chmodSync(join(main, "bin", "jev-fabric.js"), 0o755);
  json(join(main, "package.json"), {
    name: "jev-fabric",
    version,
    description: "Native process orchestration with typed, explicit Jev decisions.",
    ...common,
    main: "index.js",
    types: "index.d.ts",
    bin: { "jev-fabric": "bin/jev-fabric.js" },
    files: ["index.js", "index.d.ts", "bin/jev-fabric.js", "clients", "skills", "README.md", "LICENSE"],
    // Exact pins: the locator and the executable ship as one version.
    optionalDependencies: Object.fromEntries(platforms.map((platform) => [platform.name, version])),
    engines: { node: ">=18" },
  });

  for (const name of [...platforms.map((platform) => platform.name), "jev-fabric"]) {
    execFileSync("npm", ["pack", "--silent", "--pack-destination", out], { cwd: join(scratch, "packages", name), stdio: ["ignore", "inherit", "inherit"] });
  }
  console.log(`packed jev-fabric ${version} into ${out}`);
} finally {
  rmSync(scratch, { recursive: true, force: true });
}
