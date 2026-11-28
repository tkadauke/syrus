import path from "node:path"

// A build is either the "stable" release channel or the "test" channel (a
// test build, or a local dev build). The channel is fixed at packaging time
// and namespaces EVERY resource that would otherwise collide when a release
// and a test build run side by side on one machine: the app bundle, userData,
// the backend Docker stack, and the credentials file.
//
// This module is pure (no electron import) so it unit-tests directly; the
// electron-aware accessors that feed it app.getName()/getVersion() live in
// settings.ts (currentChannel / currentStackIdentity).
export type Channel = "stable" | "test"

// Resolve the channel from packaging signals, most authoritative first:
//   1. SYRUS_CHANNEL env — an explicit override for dev and tests.
//   2. productName — electron-builder forks this to "Syrus Test" for a test
//      build, and it is the same string that drives userData, the single-
//      instance lock, and the self-install target, so keying off it is self-
//      consistent.
//   3. version shape — a "-test.N" build, or a "0.0.x" local dev version. This
//      backstops (2): even if app.getName() ever returned the lowercase npm
//      name, a packaged test build (version -test.N) and a dev build (0.0.x)
//      still resolve to test, while a clean release stays stable.
export const resolveChannel = (signals: {
  env?: string | null
  productName?: string | null
  version?: string | null
}): Channel => {
  const env = (signals.env ?? "").trim().toLowerCase()
  if (env === "test" || env === "stable") {
    return env
  }

  if ((signals.productName ?? "").toLowerCase().includes("test")) {
    return "test"
  }

  const version = (signals.version ?? "").trim()
  if (/-test\.\d+$/.test(version) || /^0\.0\.\d+$/.test(version)) {
    return "test"
  }

  return "stable"
}

// The full set of namespaced backend resources for a channel. Every consumer
// (settings, credentialsStore, backendLifecycle, installerDriver) derives its
// values from here so the two channels can never share a stack, port, or file.
export type StackIdentity = {
  channel: Channel
  // Compose project name → determines the volume prefix and overrides the
  // compose file's `name:` default.
  project: string
  // ~/.syrus/local[-test] — the .env + synced docker-compose.yml live here.
  stateDir: string
  // <project>_syrus-data / <project>_syrus-search — the named volumes Compose
  // creates under `project`.
  dataVolume: string
  searchVolume: string
  // The default host port for a fresh install (an existing .env owns its own).
  defaultPort: number
  // Absolute path to the CLI-shared credentials file for this channel.
  credentialsFile: string
}

export const stackIdentity = (channel: Channel, homeDir: string): StackIdentity => {
  const test = channel === "test"
  const project = test ? "syrus-test" : "syrus"
  const syrusHome = path.join(homeDir, ".syrus")
  return {
    channel,
    project,
    stateDir: path.join(syrusHome, test ? "local-test" : "local"),
    dataVolume: `${project}_syrus-data`,
    searchVolume: `${project}_syrus-search`,
    defaultPort: test ? 3001 : 3000,
    credentialsFile: path.join(syrusHome, test ? "credentials.test" : "credentials")
  }
}

// The display / product name for a channel. This MUST be forced at runtime via
// app.setName() before anything reads userData, because Electron derives
// app.getName() (and therefore the userData dir + single-instance lock) from
// the bundled package.json — which stays "Syrus" even when electron-builder's
// -c.productName renames the .app bundle to "Syrus Test.app". Without the
// override a test build's userData/lock collide with the production install.
export const channelProductName = (channel: Channel): string =>
  channel === "test" ? "Syrus Test" : "Syrus"

// Classify a backend image tag by channel shape. Release tags are semver /
// `latest`; test tags are `test-<sha>` or `test-<X.Y.Z-test.N>`. Used by
// imageCleanup so one channel's update never retires the other channel's
// image (both channels pull from the same syrus-backend repository).
export const tagChannel = (tag: string): Channel =>
  /^test-/.test(tag) || /-test\.\d+$/.test(tag) ? "test" : "stable"
