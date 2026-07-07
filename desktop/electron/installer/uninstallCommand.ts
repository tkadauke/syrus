// Argument planning for "Uninstall Syrus…" (main.ts). Pure — no electron
// import — so vitest can cover the flag mapping directly
// (desktop/src/uninstallCommand.test.ts).
//
// The uninstall scripts (uninstall.sh / uninstall.ps1 at the repo root,
// staged into <Resources>/backend by scripts/stage-backend-assets.mjs)
// confirm interactively by default; the desktop app shows its own native
// confirmation dialog, so the spawn always passes --yes. The dialog's
// "Also delete my Syrus data" checkbox is the INVERSE of the scripts'
// --keep-data flag: unchecked (the default) preserves ~/.syrus (encryption
// keys, credentials), the docker data volumes, and the app settings.
//
// `appPath` tells uninstall.sh where the RUNNING app bundle actually lives
// (self-install may have copied it into /Applications or ~/Applications —
// the script's default guess only covers ~/Applications). Passed as a single
// `--app-path=<abs path>` token; uninstall.sh validates it (absolute, ends
// in /Syrus.app, under /Applications or ~/Applications). darwin-only by
// contract: main.ts derives it only there, and the win32 branch never
// forwards it — on Windows the NSIS uninstaller owns app removal.
export const buildUninstallArgs = (keepData: boolean, appPath: string | null = null): string[] => [
  "--yes",
  ...(keepData ? ["--keep-data"] : []),
  ...(appPath ? [`--app-path=${appPath}`] : [])
]

export type UninstallCommand = { command: string; args: string[] }

export const uninstallCommand = (
  scriptPath: string,
  keepData: boolean,
  platform: NodeJS.Platform = process.platform,
  appPath: string | null = null
): UninstallCommand =>
  platform === "win32"
    ? {
        command: "powershell.exe",
        // -File (not -Command) so the flags pass through verbatim. Unlike
        // installerCommand, no -NonInteractive: --yes already skips the
        // prompt, and the detached script runs in its own console window so
        // the user can watch teardown progress after the app quits.
        // No --app-path here: uninstall.ps1 doesn't take it (NSIS removes
        // the app), and forwarding it anyway would trip the script's
        // unknown-flag handling.
        args: ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", scriptPath, ...buildUninstallArgs(keepData)]
      }
    : { command: "/bin/bash", args: [scriptPath, ...buildUninstallArgs(keepData, appPath)] }
