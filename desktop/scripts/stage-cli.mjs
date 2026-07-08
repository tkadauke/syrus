// Builds the Syrus CLI (a pure-Go binary — CGO_ENABLED=0, so no C toolchain
// needed) for macOS and Windows on both architectures and stages it into
// resources/cli/, which electron-builder bundles at <Resources>/cli with a
// per-platform filter (mac DMGs carry only the darwin binaries, NSIS only
// the windows ones — see electron-builder.yml). The app's Preferences offer
// a one-click install from there (see "install-syrus-cli" in
// electron/main.ts).
//
// Naming mirrors Electron's runtime identifiers so main.ts can derive the
// source as syrus-<process.platform>-<process.arch>[.exe]:
//   syrus-darwin-arm64, syrus-darwin-x64, syrus-win32-arm64.exe,
//   syrus-win32-x64.exe
//
// Dev builds skip with a notice when Go isn't available — the app then
// simply shows manual install guidance instead of the one-click button.
// Release builds (SYRUS_RELEASE_BUILD=1) HARD-FAIL instead: 0.1.1 and 0.1.2
// shipped with no Resources/cli because the mac runner had no Go and this
// script exited 0 after wiping the staging dir, so every CLI/skill install
// in the released app died with ENOENT. A release without the bundled CLI
// is a broken release, not a degraded one.
import { execFileSync } from "node:child_process"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const desktopRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
const cliRoot = path.resolve(desktopRoot, "..", "cli")
const stagingDir = path.join(desktopRoot, "resources", "cli")

fs.rmSync(stagingDir, { recursive: true, force: true })
fs.mkdirSync(stagingDir, { recursive: true })

let goBinary = "go"
try {
  execFileSync(goBinary, ["version"], { stdio: "ignore" })
} catch {
  const homebrewGo = "/opt/homebrew/bin/go"
  if (fs.existsSync(homebrewGo)) {
    goBinary = homebrewGo
  } else if (process.env.SYRUS_RELEASE_BUILD === "1") {
    // Release builds must never ship without the bundled CLI (the 0.1.1/0.1.2
    // regression). CI provides Go via actions/setup-go pinned to cli/go.mod.
    console.error(
      "stage-cli: Go toolchain not found and SYRUS_RELEASE_BUILD=1 — a release build MUST bundle the Syrus CLI. " +
        "Add actions/setup-go (go-version-file: cli/go.mod) to the workflow, or install Go locally, and rebuild."
    )
    process.exit(1)
  } else {
    console.log("stage-cli: Go not found — skipping CLI bundling (Preferences will show manual install guidance)")
    process.exit(0)
  }
}

const targets = [
  { goos: "darwin", platform: "darwin", suffix: "" },
  { goos: "windows", platform: "win32", suffix: ".exe" }
]

for (const target of targets) {
  for (const arch of ["arm64", "amd64"]) {
    const outName = `syrus-${target.platform}-${arch === "amd64" ? "x64" : arch}${target.suffix}`
    execFileSync(goBinary, ["build", "-trimpath", "-o", path.join(stagingDir, outName), "."], {
      cwd: cliRoot,
      env: { ...process.env, CGO_ENABLED: "0", GOOS: target.goos, GOARCH: arch },
      stdio: "inherit"
    })
    fs.chmodSync(path.join(stagingDir, outName), 0o755)
  }
}

console.log(`Staged Syrus CLI binaries into ${stagingDir}`)
