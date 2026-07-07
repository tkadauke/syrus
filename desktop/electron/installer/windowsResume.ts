import { execFile } from "node:child_process"
import { promisify } from "node:util"

const execFileAsync = promisify(execFile)

// Resume-after-reboot for the Windows onboarding flow. Docker Desktop's
// installer (and the one-click WSL 2 install) can force a Windows reboot in
// the middle of setup — the field failure: the wizard never came back and the
// user had to start over. HKCU RunOnce is Microsoft's blessed mechanism for
// exactly this ("transient conditions, such as to complete application
// setup"): the value fires once at that user's next logon and is deleted
// before the command runs. HKCU (not HKLM) because it needs no elevation and
// fires for the user who was mid-setup.
//
// The RunOnce entry only guarantees the app LAUNCHES after the reboot; the
// persisted onboardingResumeLocal flag (settings.ts) is what makes the wizard
// jump back into the local flow — so a plain manual relaunch resumes too, and
// a fired-but-crashed resume still works on the next start.
const RUN_ONCE_KEY = "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce"
const RUN_ONCE_VALUE = "SyrusResumeSetup"

// Exported for tests: the exact reg.exe argv. The command line must quote the
// exe path (profile paths contain spaces) and stay under RunOnce's 260-char
// data limit — Electron's execPath is well under it.
export const runOnceAddArgs = (execPath: string): string[] => [
  "add",
  RUN_ONCE_KEY,
  "/v",
  RUN_ONCE_VALUE,
  "/t",
  "REG_SZ",
  "/d",
  `"${execPath}" --resume-setup`,
  "/f"
]

export const runOnceDeleteArgs = (): string[] => ["delete", RUN_ONCE_KEY, "/v", RUN_ONCE_VALUE, "/f"]

// Best-effort by design: a failed registration must not block the download
// flow (the persisted flag still resumes on manual relaunch), and a failed
// delete leaves only a one-shot no-op launch behind.
export const registerRunOnceResume = async (execPath: string = process.execPath): Promise<void> => {
  if (process.platform !== "win32") {
    return
  }

  try {
    await execFileAsync("reg.exe", runOnceAddArgs(execPath), { timeout: 10_000, windowsHide: true })
  } catch {
    // Persisted-flag fallback covers this.
  }
}

export const clearRunOnceResume = async (): Promise<void> => {
  if (process.platform !== "win32") {
    return
  }

  try {
    await execFileAsync("reg.exe", runOnceDeleteArgs(), { timeout: 10_000, windowsHide: true })
  } catch {
    // Value absent (already fired or never registered) — fine.
  }
}
