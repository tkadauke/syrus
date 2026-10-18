#!/usr/bin/env node

import fs from "node:fs";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { extractElectronZip } from "./extract-electron.mjs";

const require = createRequire(import.meta.url);

const electronPackageJsonPath = require.resolve("electron/package.json");
const electronDir = path.dirname(electronPackageJsonPath);
const electronPackage = require(electronPackageJsonPath);
const platform = process.env.npm_config_platform || os.platform();
const arch = process.env.npm_config_arch || process.arch;
const platformPath = getPlatformPath(platform);
const distPath = path.join(electronDir, "dist");
const pathFile = path.join(electronDir, "path.txt");

if (isInstalled()) {
  process.exit(0);
}

const { downloadArtifact } = require("@electron/get");
const checksums = shouldUseRemoteChecksums()
  ? undefined
  : require(path.join(electronDir, "checksums.json"));

const artifactPath = await downloadArtifact({
  version: electronPackage.version,
  artifactName: "electron",
  force: process.env.force_no_cache === "true",
  cacheRoot: process.env.electron_config_cache,
  checksums,
  platform,
  arch,
});

fs.rmSync(distPath, { recursive: true, force: true });
fs.mkdirSync(distPath, { recursive: true });

await extractElectronZip(artifactPath, distPath);

const extractedTypeDefinitions = path.join(distPath, "electron.d.ts");
if (fs.existsSync(extractedTypeDefinitions)) {
  fs.renameSync(extractedTypeDefinitions, path.join(electronDir, "electron.d.ts"));
}

fs.writeFileSync(pathFile, platformPath);

if (!isInstalled()) {
  throw new Error(
    `Electron runtime did not install correctly. Expected ${path.join(distPath, platformPath)}.`,
  );
}

function isInstalled() {
  if (!fs.existsSync(pathFile)) return false;

  const installedPath = fs.readFileSync(pathFile, "utf8");
  if (installedPath !== platformPath) return false;

  return fs.existsSync(path.join(distPath, installedPath));
}

function shouldUseRemoteChecksums() {
  return Boolean(
    process.env.electron_use_remote_checksums ||
      process.env.npm_config_electron_use_remote_checksums,
  );
}

function getPlatformPath(platform) {
  switch (platform) {
    case "mas":
    case "darwin":
      return "Electron.app/Contents/MacOS/Electron";
    case "freebsd":
    case "openbsd":
    case "linux":
      return "electron";
    case "win32":
      return "electron.exe";
    default:
      throw new Error(`Electron builds are not available on platform: ${platform}`);
  }
}
