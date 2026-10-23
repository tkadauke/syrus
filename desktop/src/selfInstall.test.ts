import { afterEach, describe, expect, it, vi } from "vitest"
import {
  bundlePathFromExecPath,
  chooseInstallTarget,
  compareVersions,
  installBundle,
  installDecisionForResponse,
  installFailedPrompt,
  installedBundleVersion,
  launchFailedPrompt,
  launchInstalledCopy,
  replacePrompt,
  resolveInstallTarget,
  shouldSelfInstall
} from "../electron/selfInstall"

// selfInstall.ts promisifies execFile AT MODULE LOAD, so the async mock must
// be registered under the custom-promisify symbol for promisify() to pick it
// up. spawn is reached via a dynamic import, which resolves to the same
// mocked module. The path helpers above are pure, so the mock is inert for
// the pre-existing tests.
const { execFileAsyncMock, execFileMock, spawnMock, unrefMock } = vi.hoisted(() => {
  const execFileAsyncMock = vi.fn(async (..._args: unknown[]) => ({ stdout: "", stderr: "" }))
  const execFileMock = Object.assign(vi.fn(), {
    [Symbol.for("nodejs.util.promisify.custom")]: execFileAsyncMock
  })
  const unrefMock = vi.fn()
  const spawnMock = vi.fn((..._args: unknown[]) => ({ unref: unrefMock }))
  return { execFileAsyncMock, execFileMock, spawnMock, unrefMock }
})

// installBundle/resolveInstallTarget touch the filesystem through the
// fs/promises default export; the mock keeps the suite hermetic.
const { accessMock, mkdirMock, renameMock, rmMock } = vi.hoisted(() => ({
  accessMock: vi.fn(async (..._args: unknown[]) => undefined),
  mkdirMock: vi.fn(async (..._args: unknown[]) => undefined),
  renameMock: vi.fn(async (..._args: unknown[]) => undefined),
  rmMock: vi.fn(async (..._args: unknown[]) => undefined)
}))

// Vitest's node-builtin interop resolves through the default export, so the
// factory must provide both the default object and the named exports.
vi.mock("node:child_process", () => ({
  default: { execFile: execFileMock, spawn: spawnMock },
  execFile: execFileMock,
  spawn: spawnMock
}))

vi.mock("node:fs/promises", () => {
  const fsMock = {
    access: accessMock,
    mkdir: mkdirMock,
    rename: renameMock,
    rm: rmMock,
    constants: { W_OK: 2 }
  }
  return { default: fsMock, ...fsMock }
})

const home = "/Users/operator"
const base = { isPackaged: true, platform: "darwin" as NodeJS.Platform, homeDir: home }

afterEach(() => {
  vi.clearAllMocks()
  // Some tests swap implementations (rejections, per-path behavior); restore
  // the benign defaults so ordering never leaks between tests.
  execFileAsyncMock.mockImplementation(async (..._args: unknown[]) => ({ stdout: "", stderr: "" }))
  accessMock.mockImplementation(async (..._args: unknown[]) => undefined)
  renameMock.mockImplementation(async (..._args: unknown[]) => undefined)
})

describe("bundlePathFromExecPath", () => {
  it("walks from the binary to the .app bundle root", () => {
    expect(bundlePathFromExecPath("/Volumes/Syrus 0.1.0/Syrus.app/Contents/MacOS/Syrus")).toBe("/Volumes/Syrus 0.1.0/Syrus.app")
  })
})

describe("shouldSelfInstall", () => {
  it("installs when running from a mounted DMG", () => {
    expect(shouldSelfInstall({ ...base, bundlePath: "/Volumes/Syrus 0.1.0/Syrus.app" })).toBe(true)
  })

  it("installs when running from Downloads", () => {
    expect(shouldSelfInstall({ ...base, bundlePath: `${home}/Downloads/Syrus.app` })).toBe(true)
  })

  it("does not reinstall from /Applications or ~/Applications", () => {
    expect(shouldSelfInstall({ ...base, bundlePath: "/Applications/Syrus.app" })).toBe(false)
    expect(shouldSelfInstall({ ...base, bundlePath: `${home}/Applications/Syrus.app` })).toBe(false)
  })

  it("stays put for dev (unpackaged) builds and non-mac platforms", () => {
    expect(shouldSelfInstall({ ...base, isPackaged: false, bundlePath: "/Volumes/Syrus/Syrus.app" })).toBe(false)
    expect(shouldSelfInstall({ ...base, platform: "linux" as NodeJS.Platform, bundlePath: "/opt/Syrus.app" })).toBe(false)
  })

  it("does not guess when the exec path is not inside a .app bundle", () => {
    expect(shouldSelfInstall({ ...base, bundlePath: "/Volumes/Syrus/weird-layout" })).toBe(false)
  })
})

describe("compareVersions", () => {
  it("compares release versions numerically, not lexicographically", () => {
    expect(compareVersions("0.1.10", "0.1.9")).toBe("newer")
    expect(compareVersions("0.1.9", "0.1.10")).toBe("older")
    expect(compareVersions("0.2.0", "0.2.0")).toBe("same")
    expect(compareVersions("1.0", "0.9.9")).toBe("newer")
  })

  it("treats 0.0.0 on either side as unknown — a dev build never claims newer", () => {
    expect(compareVersions("0.0.0", "0.1.3")).toBe("unknown")
    expect(compareVersions("0.1.3", "0.0.0")).toBe("unknown")
    expect(compareVersions("0.0.0", "0.0.0")).toBe("unknown")
  })

  it("treats missing or unparseable versions as unknown", () => {
    expect(compareVersions(null, "0.1.3")).toBe("unknown")
    expect(compareVersions("0.1.3", null)).toBe("unknown")
    expect(compareVersions("banana", "0.1.3")).toBe("unknown")
    expect(compareVersions("", "0.1.3")).toBe("unknown")
  })

  it("never truncates prerelease suffixes into comparable numbers", () => {
    // parseInt would read "4-beta" as 4 and misclassify; strict segments
    // make prerelease/malformed versions unknown instead.
    expect(compareVersions("0.1.4-beta.1", "0.1.3")).toBe("unknown")
    expect(compareVersions("0.1.4", "0.1.4-rc.2")).toBe("unknown")
    expect(compareVersions("0.1.", "0.1.0")).toBe("unknown")
  })
})

describe("chooseInstallTarget", () => {
  const facts = { bundleName: "Syrus.app", homeDir: home }

  it("prefers a fresh install into /Applications when it is writable", () => {
    expect(chooseInstallTarget({ ...facts, systemExists: false, userExists: false, systemWritable: true })).toEqual({
      path: "/Applications/Syrus.app",
      existingInstall: false
    })
  })

  it("falls back to ~/Applications when /Applications needs admin rights", () => {
    expect(chooseInstallTarget({ ...facts, systemExists: false, userExists: false, systemWritable: false })).toEqual({
      path: `${home}/Applications/Syrus.app`,
      existingInstall: false
    })
  })

  it("replaces the existing install wherever it lives", () => {
    expect(chooseInstallTarget({ ...facts, systemExists: true, userExists: false, systemWritable: true })).toEqual({
      path: "/Applications/Syrus.app",
      existingInstall: true
    })
    // An existing ~/Applications install wins over a fresh /Applications
    // install — replacing beats creating a coexisting duplicate.
    expect(chooseInstallTarget({ ...facts, systemExists: false, userExists: true, systemWritable: true })).toEqual({
      path: `${home}/Applications/Syrus.app`,
      existingInstall: true
    })
  })

  it("prefers /Applications when both locations hold an install", () => {
    expect(chooseInstallTarget({ ...facts, systemExists: true, userExists: true, systemWritable: true })).toEqual({
      path: "/Applications/Syrus.app",
      existingInstall: true
    })
  })

  it("never targets a /Applications copy it cannot replace without admin rights", () => {
    // A standard user with an admin-installed /Applications/Syrus.app: the
    // replace must not aim at a guaranteed EACCES failure. The user copy is
    // replaced when it exists…
    expect(chooseInstallTarget({ ...facts, systemExists: true, userExists: true, systemWritable: false })).toEqual({
      path: `${home}/Applications/Syrus.app`,
      existingInstall: true
    })
    // …and a fresh ~/Applications install happens when it does not (the
    // admin copy stays; instance takeover handles the duality at launch).
    expect(chooseInstallTarget({ ...facts, systemExists: true, userExists: false, systemWritable: false })).toEqual({
      path: `${home}/Applications/Syrus.app`,
      existingInstall: false
    })
  })
})

describe("resolveInstallTarget", () => {
  it("probes both Applications folders plus writability and delegates to the chooser", async () => {
    accessMock.mockImplementation(async (...args: unknown[]) => {
      const [target, mode] = args as [string, number?]
      // /Applications exists but is not writable; no install anywhere.
      if (target === "/Applications" && mode === 2) throw new Error("EACCES")
      if (target.endsWith("Syrus.app")) throw new Error("ENOENT")
      return undefined
    })

    await expect(resolveInstallTarget("/Volumes/Syrus 0.1.4/Syrus.app", home)).resolves.toEqual({
      path: `${home}/Applications/Syrus.app`,
      existingInstall: false
    })

    expect(accessMock).toHaveBeenCalledWith("/Applications/Syrus.app", undefined)
    expect(accessMock).toHaveBeenCalledWith(`${home}/Applications/Syrus.app`, undefined)
    expect(accessMock).toHaveBeenCalledWith("/Applications", 2)
  })
})

describe("installedBundleVersion", () => {
  it("reads CFBundleShortVersionString via PlistBuddy", async () => {
    execFileAsyncMock.mockResolvedValueOnce({ stdout: "0.1.3\n", stderr: "" })

    await expect(installedBundleVersion("/Applications/Syrus.app")).resolves.toBe("0.1.3")
    expect(execFileAsyncMock).toHaveBeenCalledWith("/usr/libexec/PlistBuddy", [
      "-c",
      "Print :CFBundleShortVersionString",
      "/Applications/Syrus.app/Contents/Info.plist"
    ])
  })

  it("falls back to defaults(1) when PlistBuddy fails", async () => {
    execFileAsyncMock.mockRejectedValueOnce(new Error("no PlistBuddy"))
    execFileAsyncMock.mockResolvedValueOnce({ stdout: "0.2.0\n", stderr: "" })

    await expect(installedBundleVersion("/Applications/Syrus.app")).resolves.toBe("0.2.0")
    // defaults wants the plist path without the extension.
    expect(execFileAsyncMock).toHaveBeenCalledWith("/usr/bin/defaults", ["read", "/Applications/Syrus.app/Contents/Info", "CFBundleShortVersionString"])
  })

  it("returns null (unknown) when no reader can produce a version", async () => {
    execFileAsyncMock.mockRejectedValue(new Error("nope"))

    await expect(installedBundleVersion("/Applications/Syrus.app")).resolves.toBeNull()
  })
})

describe("replacePrompt", () => {
  const targetPath = "/Applications/Syrus.app"

  it("names both versions and flags the newer copy", () => {
    const prompt = replacePrompt({ existingVersion: "0.1.3", newVersion: "0.1.4", targetPath })
    expect(prompt.message).toBe("Install Syrus to Applications?")
    expect(prompt.detail).toContain("replace Syrus 0.1.3 in /Applications with Syrus 0.1.4")
    expect(prompt.detail).toContain("(this copy appears newer)")
    expect(prompt.buttons).toEqual(["Replace", "Keep Existing"])
    expect(prompt.replaceIndex).toBe(0)
    expect(prompt.cancelId).toBe(1)
  })

  it("uses the shared locale for representative dialog copy", () => {
    const prompt = replacePrompt({ existingVersion: "0.1.3", newVersion: "0.1.4", targetPath, locale: "de" })
    expect(prompt.message).toBe("Syrus in Programme installieren?")
    expect(prompt.buttons).toEqual(["Ersetzen", "Vorhandene behalten"])
    expect(prompt.detail).not.toContain("This will replace")
  })

  it("flags a downgrade as the installed copy appearing newer", () => {
    const prompt = replacePrompt({ existingVersion: "0.2.0", newVersion: "0.1.4", targetPath })
    expect(prompt.detail).toContain("(the installed copy appears newer)")
  })

  it("never claims a 0.0.0 dev build is newer than a versioned install", () => {
    const prompt = replacePrompt({ existingVersion: "0.1.3", newVersion: "0.0.0", targetPath })
    expect(prompt.detail).toContain("replace Syrus 0.1.3 in /Applications with an unknown-version dev build")
    expect(prompt.detail).not.toContain("appears newer")
  })

  it("names a prerelease version string instead of calling it a dev build", () => {
    // The exact user-reported dialog: a 0.1.4-test.1 DMG over an old dev
    // build read "replace an unknown-version dev build with an
    // unknown-version dev build". The prerelease is unparseable for ORDERING
    // (no newer/older claim) but its string must be shown.
    const prompt = replacePrompt({ existingVersion: "0.0.0", newVersion: "0.1.4-test.1", targetPath })
    expect(prompt.detail).toContain("replace an unknown-version dev build in /Applications with Syrus 0.1.4-test.1")
    expect(prompt.detail).not.toContain("appears newer")
  })

  it("describes an unreadable installed version as an unknown-version dev build", () => {
    const prompt = replacePrompt({ existingVersion: null, newVersion: "0.1.4", targetPath })
    expect(prompt.detail).toContain("replace an unknown-version dev build in /Applications with Syrus 0.1.4")
    expect(prompt.detail).not.toContain("appears newer")
  })

  it("names the ACTUAL target directory when the replace lands in ~/Applications", () => {
    const prompt = replacePrompt({
      existingVersion: "0.1.3",
      newVersion: "0.1.4",
      targetPath: `${home}/Applications/Syrus.app`
    })
    expect(prompt.detail).toContain(`in ${home}/Applications`)
  })
})

describe("installDecisionForResponse", () => {
  const prompt = replacePrompt({
    existingVersion: "0.1.3",
    newVersion: "0.1.4",
    targetPath: "/Applications/Syrus.app"
  })

  it("replaces on the Replace button", () => {
    expect(installDecisionForResponse(prompt, prompt.replaceIndex)).toBe("replace")
  })

  it("launches the existing install on decline — never a DMG session", () => {
    expect(installDecisionForResponse(prompt, prompt.cancelId)).toBe("launch-existing")
  })
})

describe("installFailedPrompt", () => {
  it("points at the manual drag and offers only Quit", () => {
    const prompt = installFailedPrompt({ bundleName: "Syrus.app", targetPath: "/Applications/Syrus.app" })
    expect(prompt.message).toBe("Syrus could not be installed.")
    expect(prompt.detail).toContain("Copying Syrus.app to /Applications failed.")
    expect(prompt.detail).toContain("Drag Syrus into your Applications folder")
    expect(prompt.buttons).toEqual(["Quit"])
  })

  it("copes with the target being unknown", () => {
    const prompt = installFailedPrompt({ bundleName: "Syrus.app", targetPath: null })
    expect(prompt.detail).toContain("Copying Syrus.app failed.")
  })

  it("surfaces the underlying error so failures are diagnosable", () => {
    const prompt = installFailedPrompt({
      bundleName: "Syrus.app",
      targetPath: "/Applications/Syrus.app",
      reason: "EACCES: permission denied"
    })
    expect(prompt.detail).toContain("(EACCES: permission denied)")
  })
})

describe("launchFailedPrompt", () => {
  it("tells the user the just-installed copy is in place but must be opened manually", () => {
    const prompt = launchFailedPrompt({
      targetPath: "/Applications/Syrus.app",
      justInstalled: true,
      reason: "open exited 1"
    })
    expect(prompt.message).toBe("Syrus was installed but could not be opened.")
    expect(prompt.detail).toContain("Syrus was installed to /Applications but couldn't be opened automatically.")
    expect(prompt.detail).toContain("Launch it from Applications manually.")
    expect(prompt.detail).toContain("(open exited 1)")
    expect(prompt.buttons).toEqual(["Quit"])
  })

  it("names the existing copy's path on a Keep-Existing launch failure", () => {
    const prompt = launchFailedPrompt({
      targetPath: `${home}/Applications/Syrus.app`,
      justInstalled: false
    })
    expect(prompt.message).toBe("Syrus could not open the installed copy.")
    expect(prompt.detail).toContain(`Syrus couldn't open the installed copy at ${home}/Applications/Syrus.app.`)
    expect(prompt.detail).toContain("Launch it from Applications manually.")
  })
})

describe("installBundle", () => {
  const target = "/Applications/Syrus.app"
  const staging = `${target}.installing-${process.pid}`
  const previous = `${target}.previous-${process.pid}`

  it("stages via signature-preserving ditto, swaps by rename, and strips quarantine", async () => {
    await expect(installBundle("/Volumes/Syrus 0.1.4/Syrus.app", target)).resolves.toBe(target)

    expect(mkdirMock).toHaveBeenCalledWith("/Applications", { recursive: true })
    expect(execFileAsyncMock).toHaveBeenCalledWith("/usr/bin/ditto", ["/Volumes/Syrus 0.1.4/Syrus.app", staging])
    // Destroy-then-copy is the forbidden shape: the FULL copy must exist in
    // staging before the existing install is touched, and the target is only
    // ever renamed aside — never rm'd.
    const dittoIndex = execFileAsyncMock.mock.calls.findIndex((call) => call[0] === "/usr/bin/ditto")
    const dittoOrder = execFileAsyncMock.mock.invocationCallOrder[dittoIndex]
    expect(renameMock.mock.invocationCallOrder.every((order) => order > dittoOrder)).toBe(true)
    expect(renameMock.mock.calls).toEqual([
      [target, previous],
      [staging, target]
    ])
    expect(rmMock.mock.calls).not.toContainEqual([target, { recursive: true, force: true }])
    // The moved-aside previous install is dropped only after the swap.
    expect(rmMock).toHaveBeenCalledWith(previous, { recursive: true, force: true })
    expect(execFileAsyncMock).toHaveBeenCalledWith("/usr/bin/xattr", ["-dr", "com.apple.quarantine", target])
  })

  it("leaves the existing install untouched when the copy itself fails", async () => {
    execFileAsyncMock.mockImplementation(async (...args: unknown[]) => {
      if (args[0] === "/usr/bin/ditto") throw new Error("disk full")
      return { stdout: "", stderr: "" }
    })

    await expect(installBundle("/Volumes/Syrus/Syrus.app", target)).rejects.toThrow("disk full")
    // No rename ever happened; only the half-written staging copy is removed.
    expect(renameMock).not.toHaveBeenCalled()
    expect(rmMock).toHaveBeenCalledWith(staging, { recursive: true, force: true })
    expect(rmMock.mock.calls).not.toContainEqual([target, { recursive: true, force: true }])
  })

  it("restores the previous install when the final swap fails — never zero installs", async () => {
    renameMock.mockImplementation(async (...args: unknown[]) => {
      if (args[0] === staging) throw new Error("rename blocked")
      return undefined
    })

    await expect(installBundle("/Volumes/Syrus/Syrus.app", target)).rejects.toThrow("rename blocked")
    expect(renameMock.mock.calls).toEqual([
      [target, previous], // move the existing install aside
      [staging, target], // failed swap
      [previous, target] // restore the existing install
    ])
    expect(rmMock).toHaveBeenCalledWith(staging, { recursive: true, force: true })
  })

  it("skips the move-aside dance when nothing is installed at the target", async () => {
    renameMock.mockImplementation(async (...args: unknown[]) => {
      if (args[1] === previous) throw Object.assign(new Error("ENOENT"), { code: "ENOENT" })
      return undefined
    })

    await expect(installBundle("/Volumes/Syrus/Syrus.app", target)).resolves.toBe(target)
    // Fresh install: no previous to clean up (and none to restore).
    expect(rmMock.mock.calls).not.toContainEqual([previous, { recursive: true, force: true }])
  })

  it("treats the quarantine strip as best-effort", async () => {
    execFileAsyncMock.mockImplementation(async (...args: unknown[]) => {
      if (args[0] === "/usr/bin/xattr") throw new Error("xattr sad")
      return { stdout: "", stderr: "" }
    })

    await expect(installBundle("/Volumes/Syrus/Syrus.app", `${home}/Applications/Syrus.app`)).resolves.toBe(`${home}/Applications/Syrus.app`)
  })

  it("propagates a failed copy so the caller can explain and quit", async () => {
    execFileAsyncMock.mockRejectedValueOnce(new Error("read-only volume"))

    await expect(installBundle("/Volumes/Syrus/Syrus.app", target)).rejects.toThrow("read-only volume")
  })
})

describe("launchInstalledCopy", () => {
  const realPlatform = process.platform

  const setPlatform = (value: string) => {
    Object.defineProperty(process, "platform", { value, configurable: true })
  }

  afterEach(() => {
    Object.defineProperty(process, "platform", { value: realPlatform, configurable: true })
  })

  it("launches the installed .app through open(1) on macOS", async () => {
    setPlatform("darwin")

    await launchInstalledCopy(`${home}/Applications/Syrus.app`)

    expect(execFileAsyncMock).toHaveBeenCalledWith("/usr/bin/open", ["-n", `${home}/Applications/Syrus.app`])
    expect(spawnMock).not.toHaveBeenCalled()
  })

  it("spawns the installed exe detached on Windows and unrefs it", async () => {
    setPlatform("win32")
    const exe = "C:\\Users\\op\\AppData\\Local\\Programs\\Syrus\\Syrus.exe"

    await launchInstalledCopy(exe)

    // Detached + unref: the new copy must outlive this (about-to-quit)
    // process — the instance-takeover "Switch" path depends on it.
    expect(spawnMock).toHaveBeenCalledWith(exe, [], { detached: true, stdio: "ignore" })
    expect(unrefMock).toHaveBeenCalledTimes(1)
    expect(execFileAsyncMock).not.toHaveBeenCalled()
  })
})
