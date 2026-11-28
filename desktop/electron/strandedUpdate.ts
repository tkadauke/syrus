import { compareVersions } from "./selfInstall.js"

export type ShipItState = {
  updateBundleURL: string
}

export const shouldRecoverStrandedUpdate = (input: {
  state: ShipItState | null
  stagedVersion: string | null
  runningVersion: string
}): boolean =>
  Boolean(input.state?.updateBundleURL.trim()) &&
  compareVersions(input.stagedVersion, input.runningVersion) === "newer"
