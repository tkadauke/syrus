import { describe, expect, it } from "vitest"
import { runOnceAddArgs, runOnceDeleteArgs } from "../electron/installer/windowsResume"

// The reboot-resume contract: Docker Desktop / WSL installs can force a
// Windows reboot mid-onboarding, and HKCU RunOnce is what relaunches Syrus at
// the next logon so setup continues instead of stranding the user (the
// persisted onboardingResumeLocal flag then jumps back into the local flow).
describe("windowsResume RunOnce registration", () => {
  it("registers under HKCU RunOnce with a quoted exe path", () => {
    // Profile paths contain spaces (C:\Users\First Last\...) — an unquoted
    // command line would truncate at the first space and launch nothing.
    const args = runOnceAddArgs("C:\\Users\\First Last\\AppData\\Local\\Programs\\Syrus\\Syrus.exe")

    expect(args[0]).toBe("add")
    expect(args[1]).toBe("HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce")
    expect(args).toContain("SyrusResumeSetup")
    expect(args).toContain("REG_SZ")
    expect(args).toContain('"C:\\Users\\First Last\\AppData\\Local\\Programs\\Syrus\\Syrus.exe" --resume-setup')
    expect(args[args.length - 1]).toBe("/f")
  })

  it("stays under RunOnce's 260-char command-line limit for realistic paths", () => {
    const args = runOnceAddArgs("C:\\Users\\Somebody\\AppData\\Local\\Programs\\Syrus\\Syrus.exe")
    const commandLine = args[args.indexOf("/d") + 1]

    expect(commandLine.length).toBeLessThan(260)
  })

  it("deletes the same value it registered", () => {
    const args = runOnceDeleteArgs()

    expect(args[0]).toBe("delete")
    expect(args[1]).toBe("HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce")
    expect(args).toContain("SyrusResumeSetup")
    expect(args[args.length - 1]).toBe("/f")
  })
})
