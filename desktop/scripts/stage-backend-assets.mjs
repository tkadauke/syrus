#!/usr/bin/env node
// Stages the backend installer assets that electron-builder bundles into the
// app at <Resources>/backend (see extraResources in electron-builder.yml).
// The onboarding flow drives this exact install.sh; manifest.json pins the
// backend image tag to this app release, which is the contract read by
// desktop/electron/installer/installPaths.ts (readBackendManifest).
//
// Everything staged here ends up sealed by the code signature — install.sh
// writes its mutable state to --target-dir, never next to itself.
import { execSync } from "node:child_process"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const desktopRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const repoRoot = path.resolve(desktopRoot, "..")
const stagingDir = path.join(desktopRoot, "resources", "backend")

const pkg = JSON.parse(fs.readFileSync(path.join(desktopRoot, "package.json"), "utf8"))

fs.rmSync(stagingDir, { recursive: true, force: true })
fs.mkdirSync(stagingDir, { recursive: true })

// Both installer scripts stage unconditionally — one staging run feeds the
// mac and the Windows packaging jobs (electron-builder bundles the whole
// backend dir for every platform; the scripts are a few KB).
for (const name of ["install.sh", "install.ps1", "docker-compose.yml", "compose.env.example"]) {
  fs.copyFileSync(path.join(repoRoot, name), path.join(stagingDir, name))
}
fs.chmodSync(path.join(stagingDir, "install.sh"), 0o755)

// Release builds (SYRUS_RELEASE_BUILD=1, set by the release workflow) pin
// the image tag published by `bin/publish-image X.Y.Z`; the workflow
// verifies that tag exists before building. Everything else — including a
// plain local `npm run build` whose package.json version looks like a
// release — falls back to :latest so unpublished builds still install.
const version = String(pkg.version ?? "")
const isReleaseBuild = process.env.SYRUS_RELEASE_BUILD === "1"
const image =
  process.env.SYRUS_BACKEND_IMAGE ??
  (isReleaseBuild ? `ghcr.io/tkadauke/syrus-backend:${version}` : "ghcr.io/tkadauke/syrus-backend:latest")

// The app's own build sha (distinct from appVersion, which stays put across
// dev builds). The shell announces it via a User-Agent token so the web UI's
// BuildBadge can show exactly which app build is hosting it.
const appBuild = (() => {
  try {
    return execSync("git rev-parse --short HEAD", { cwd: repoRoot, encoding: "utf8" }).trim()
  } catch {
    return "dev"
  }
})()

fs.writeFileSync(
  path.join(stagingDir, "manifest.json"),
  `${JSON.stringify({ image, appVersion: version, appBuild }, null, 2)}\n`
)

console.log(`Staged backend assets into ${stagingDir} (image: ${image}, appBuild: ${appBuild})`)
