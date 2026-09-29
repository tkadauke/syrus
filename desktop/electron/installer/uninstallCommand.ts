// Argument planning for "Uninstall Syrus…" (main.ts). Pure — no electron
// import — so vitest can cover the flag mapping directly
// (desktop/src/uninstallCommand.test.ts).
//
// The uninstall script (uninstall.sh at the repo root, staged into
// <Resources>/backend by scripts/stage-backend-assets.mjs) confirms
// interactively by default; the desktop app shows its own native
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
// contract: main.ts derives it only there.
import type { Channel } from "../channel.js"

// The channel MUST be threaded through, or a TEST build's "Uninstall Syrus…"
// runs the scripts with their default stable channel and tears down the
// PRODUCTION stack, credentials, and settings while leaving the test install
// untouched. `--channel test` scopes every teardown to the test resources.
export const buildUninstallArgs = (
  keepData: boolean,
  appPath: string | null = null,
  channel: Channel = "stable"
): string[] => [
  "--yes",
  ...(keepData ? ["--keep-data"] : []),
  ...(appPath ? [`--app-path=${appPath}`] : []),
  ...(channel === "test" ? ["--channel", "test"] : [])
]

export type UninstallCommand = { command: string; args: string[] }

export const uninstallCommand = (
  scriptPath: string,
  keepData: boolean,
  _platform: NodeJS.Platform = process.platform,
  appPath: string | null = null,
  channel: Channel = "stable"
): UninstallCommand =>
  ({ command: "/bin/bash", args: [scriptPath, ...buildUninstallArgs(keepData, appPath, channel)] })
