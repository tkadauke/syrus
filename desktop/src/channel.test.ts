import { describe, expect, it } from "vitest"
import { resolveChannel, stackIdentity, tagChannel } from "../electron/channel"

describe("resolveChannel", () => {
  it("honors an explicit SYRUS_CHANNEL override first", () => {
    // Even a release-shaped productName/version yields test when forced.
    expect(resolveChannel({ env: "test", productName: "Syrus", version: "0.1.5" })).toBe("test")
    expect(resolveChannel({ env: "stable", productName: "Syrus Test", version: "0.1.5-test.3" })).toBe("stable")
    expect(resolveChannel({ env: " TEST " })).toBe("test")
  })

  it("reads the forked product name for a packaged test build", () => {
    expect(resolveChannel({ productName: "Syrus Test", version: "0.1.5-test.3" })).toBe("test")
  })

  it("backstops via version shape when the product name is not forked", () => {
    // -test.N packaged builds and 0.0.x local builds resolve to test
    // even if getName() returned the plain name.
    expect(resolveChannel({ productName: "Syrus", version: "0.1.5-test.3" })).toBe("test")
    expect(resolveChannel({ productName: "syrus-desktop", version: "0.0.0" })).toBe("test")
    expect(resolveChannel({ productName: "syrus-desktop", version: "0.0.1" })).toBe("test")
  })

  it("resolves a clean release to stable", () => {
    expect(resolveChannel({ productName: "Syrus", version: "0.1.5" })).toBe("stable")
    expect(resolveChannel({})).toBe("stable")
    // A -test suffix that is not the -test.N scheme does not count.
    expect(resolveChannel({ productName: "Syrus", version: "0.1.5-testflight" })).toBe("stable")
  })
})

describe("stackIdentity", () => {
  it("keeps the stable channel on the original names, port, and files", () => {
    const s = stackIdentity("stable", "/home/me")
    expect(s.project).toBe("syrus")
    expect(s.stateDir).toBe("/home/me/.syrus/local")
    expect(s.dataVolume).toBe("syrus_syrus-data")
    expect(s.searchVolume).toBe("syrus_syrus-search")
    expect(s.defaultPort).toBe(3000)
    expect(s.credentialsFile).toBe("/home/me/.syrus/credentials")
  })

  it("gives the test channel a fully isolated stack", () => {
    const s = stackIdentity("test", "/home/me")
    expect(s.project).toBe("syrus-test")
    expect(s.stateDir).toBe("/home/me/.syrus/local-test")
    expect(s.dataVolume).toBe("syrus-test_syrus-data")
    expect(s.searchVolume).toBe("syrus-test_syrus-search")
    expect(s.defaultPort).toBe(3001)
    expect(s.credentialsFile).toBe("/home/me/.syrus/credentials.test")
  })

  it("never shares a volume, port, state dir, or credentials file across channels", () => {
    const stable = stackIdentity("stable", "/home/me")
    const test = stackIdentity("test", "/home/me")
    expect(stable.dataVolume).not.toBe(test.dataVolume)
    expect(stable.searchVolume).not.toBe(test.searchVolume)
    expect(stable.stateDir).not.toBe(test.stateDir)
    expect(stable.defaultPort).not.toBe(test.defaultPort)
    expect(stable.credentialsFile).not.toBe(test.credentialsFile)
    expect(stable.project).not.toBe(test.project)
  })
})

describe("tagChannel", () => {
  it("classifies release tags as stable", () => {
    expect(tagChannel("0.1.5")).toBe("stable")
    expect(tagChannel("latest")).toBe("stable")
  })

  it("classifies test-prefixed tags as test", () => {
    expect(tagChannel("test-d0495e8e")).toBe("test")
    expect(tagChannel("test-0.1.5-test.3")).toBe("test")
    expect(tagChannel("0.1.5-test.3")).toBe("test")
  })

  // uninstall.sh's image sweep mirrors this rule; spec/desktop/uninstall_spec.rb
  // runs the script over these same tags.
  it("treats -test.<digits> as test only at the end of the tag", () => {
    expect(tagChannel("0.1.2-test.4-hotfix")).toBe("stable")
    expect(tagChannel("0.1.2-test.4.1")).toBe("stable")
  })
})
