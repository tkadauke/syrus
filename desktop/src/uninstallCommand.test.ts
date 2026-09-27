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

  // Load-bearing: without --channel a TEST build's uninstall runs the scripts
  // on the default stable channel and tears down PRODUCTION.
  it("appends --channel test only on the test channel, never stable", () => {
    expect(buildUninstallArgs(true, null, "test")).toEqual(["--yes", "--keep-data", "--channel", "test"])
    expect(buildUninstallArgs(false, "/Applications/Syrus Test.app", "test")).toEqual([
      "--yes",
      "--app-path=/Applications/Syrus Test.app",
      "--channel",
      "test"
    ])
    expect(buildUninstallArgs(true, null, "stable")).toEqual(["--yes", "--keep-data"])
    expect(buildUninstallArgs(true, null)).toEqual(["--yes", "--keep-data"])
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

  it("keeps the keep-data mapping on the shell command", () => {
    const darwin = uninstallCommand("/s/uninstall.sh", true, "darwin")
    expect(darwin.args).toContain("--keep-data")
  })

  it("threads --channel test to the shell script", () => {
    const darwin = uninstallCommand("/s/uninstall.sh", true, "darwin", "/Applications/Syrus Test.app", "test")
    expect(darwin.args).toEqual([
      "/s/uninstall.sh",
      "--yes",
      "--keep-data",
      "--app-path=/Applications/Syrus Test.app",
      "--channel",
      "test"
    ])
  })
})
