import { describe, expect, it } from "vitest"
import { buildUninstallArgs, uninstallCommand } from "../electron/installer/uninstallCommand"

// The desktop "Uninstall Syrus…" flow shows its own native confirmation, so
// the spawned script must never prompt again — and the dialog's "Also delete
// my Syrus data" checkbox is the inverse of the scripts' --keep-data flag.
describe("buildUninstallArgs", () => {
  it("always skips the script's own confirmation prompt", () => {
    expect(buildUninstallArgs(true)).toContain("--yes")
    expect(buildUninstallArgs(false)).toContain("--yes")
  })

  it("passes --keep-data when the user left the delete-data checkbox unchecked", () => {
    expect(buildUninstallArgs(true)).toEqual(["--yes", "--keep-data"])
  })

  it("omits --keep-data when the user opted into deleting their data", () => {
    expect(buildUninstallArgs(false)).toEqual(["--yes"])
  })

  it("appends --app-path=<bundle> as a single token when a bundle path is known", () => {
    // Single `--app-path=<path>` token: no separate-argument parsing for the
    // script, and spaces in the path can't split into two argv entries.
    expect(buildUninstallArgs(true, "/Applications/Syrus.app")).toEqual([
      "--yes",
      "--keep-data",
      "--app-path=/Applications/Syrus.app"
    ])
    expect(buildUninstallArgs(false, "/Applications/Syrus.app")).toEqual([
      "--yes",
      "--app-path=/Applications/Syrus.app"
    ])
  })

  it("omits --app-path when no bundle path was derived", () => {
    expect(buildUninstallArgs(true, null)).toEqual(["--yes", "--keep-data"])
    expect(buildUninstallArgs(true)).toEqual(["--yes", "--keep-data"])
  })
})

describe("uninstallCommand", () => {
  it("runs uninstall.sh through bash on macOS and Linux", () => {
    for (const platform of ["darwin", "linux"] as const) {
      expect(uninstallCommand("/res/backend/uninstall.sh", true, platform)).toEqual({
        command: "/bin/bash",
        args: ["/res/backend/uninstall.sh", "--yes", "--keep-data"]
      })
    }
  })

  it("forwards the app bundle path to uninstall.sh so the /Applications copy is removed too", () => {
    // The dialog promises to remove "the Syrus app"; self-install may have
    // put the running bundle in /Applications OR ~/Applications, so the
    // script must be told which one is real instead of guessing.
    expect(uninstallCommand("/res/backend/uninstall.sh", true, "darwin", "/Applications/Syrus.app")).toEqual({
      command: "/bin/bash",
      args: ["/res/backend/uninstall.sh", "--yes", "--keep-data", "--app-path=/Applications/Syrus.app"]
    })
  })

  it("runs uninstall.ps1 through powershell -File on Windows", () => {
    expect(uninstallCommand("C:\\res\\backend\\uninstall.ps1", false, "win32")).toEqual({
      command: "powershell.exe",
      args: [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "C:\\res\\backend\\uninstall.ps1",
        "--yes"
      ]
    })
  })

  it("never forwards --app-path on Windows — the NSIS uninstaller owns app removal there", () => {
    const windows = uninstallCommand("C:\\res\\backend\\uninstall.ps1", true, "win32", "/Applications/Syrus.app")
    expect(windows.args.some((arg) => arg.startsWith("--app-path"))).toBe(false)
    expect(windows.args).toEqual([
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      "C:\\res\\backend\\uninstall.ps1",
      "--yes",
      "--keep-data"
    ])
  })

  it("keeps the keep-data mapping identical across platforms", () => {
    const darwin = uninstallCommand("/s/uninstall.sh", true, "darwin")
    const windows = uninstallCommand("C:\\s\\uninstall.ps1", true, "win32")
    expect(darwin.args).toContain("--keep-data")
    expect(windows.args).toContain("--keep-data")
  })
})
