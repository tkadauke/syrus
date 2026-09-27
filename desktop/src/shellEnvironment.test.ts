import { describe, expect, it } from "vitest"
import { parseLoginShellEnvironment } from "../electron/shellEnvironment.js"

describe("parseLoginShellEnvironment", () => {
  it("uses the environment emitted after shell startup output", () => {
    const output = "startup banner\n__SYRUS_LOGIN_ENV__\0PATH=/managed/bin:/usr/bin\0RUBY_ROOT=/managed/ruby\0"

    expect(parseLoginShellEnvironment(output, { HOME: "/home/test", PATH: "/usr/bin" })).toEqual({
      HOME: "/home/test",
      PATH: "/managed/bin:/usr/bin",
      RUBY_ROOT: "/managed/ruby"
    })
  })

  it("preserves values containing equals signs", () => {
    const output = "__SYRUS_LOGIN_ENV__\0TOKEN=first=second\0"

    expect(parseLoginShellEnvironment(output, {})).toEqual({ TOKEN: "first=second" })
  })

  it("falls back when the marker is absent", () => {
    expect(parseLoginShellEnvironment("shell startup failed", { PATH: "/usr/bin" })).toEqual({
      PATH: "/usr/bin"
    })
  })
})
