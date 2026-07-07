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

// Both installer scripts (and their uninstall counterparts, which power the
// app's "Uninstall Syrus…" menu item) stage unconditionally — one staging run
// feeds the mac and the Windows packaging jobs (electron-builder bundles the
// whole backend dir for every platform; the scripts are a few KB).
for (const name of [
  "install.sh",
  "install.ps1",
  "uninstall.sh",
  "uninstall.ps1",
  "docker-compose.yml",
  "compose.env.example"
]) {
  fs.copyFileSync(path.join(repoRoot, name), path.join(stagingDir, name))
}
for (const shellScript of ["install.sh", "uninstall.sh"]) {
  fs.chmodSync(path.join(stagingDir, shellScript), 0o755)
}

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

// When this app build was produced. Feeds the BuildBadge's hover tooltip
// (via the SyrusDesktopBuiltAt UA token) so a diverged app/backend pair
// shows which part is older. Dev builds stamp "now" — staging runs at
// desktop build time, so the wall clock IS the build moment. Release builds
// instead derive the timestamp from HEAD's committer date, the same source
// release.yml / bin/publish-image bake into the backend image as
// SYRUS_BUILT_AT, normalized to the identical second-precision UTC ISO-8601
// form — so on a release the app and backend tooltips show the IDENTICAL
// instant. Falls back to the wall clock outside a git checkout, mirroring
// appBuild above.
const builtAt = (() => {
  if (!isReleaseBuild) return new Date().toISOString()
  try {
    const epochSeconds = execSync("git show -s --format=%ct HEAD", { cwd: repoRoot, encoding: "utf8" }).trim()
    return new Date(Number(epochSeconds) * 1000).toISOString().replace(/\.\d{3}Z$/, "Z")
  } catch {
    return new Date().toISOString()
  }
})()

fs.writeFileSync(
  path.join(stagingDir, "manifest.json"),
  `${JSON.stringify({ image, appVersion: version, appBuild, builtAt }, null, 2)}\n`
)

console.log(`Staged backend assets into ${stagingDir} (image: ${image}, appBuild: ${appBuild}, builtAt: ${builtAt})`)
