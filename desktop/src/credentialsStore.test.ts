import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

let credentialsFile = ""

vi.mock("../electron/settings.js", () => ({
  currentStackIdentity: () => ({ credentialsFile }),
}))

const { readCredentialsFile, writeCredentialsFile } = await import("../electron/credentialsStore")

describe("writeCredentialsFile", () => {
  let dir = ""

  beforeEach(async () => {
    dir = await fs.mkdtemp(path.join(os.tmpdir(), "syrus-credentials-"))
    credentialsFile = path.join(dir, ".syrus", "credentials")
  })

  afterEach(async () => {
    await fs.rm(dir, { recursive: true, force: true })
  })

  // The file is shared with the CLI. Writing the path directly followed a
  // symlink into its target, and a pre-existing loose file kept its mode
  // (writeFile's mode applies only on create) while it held the new token.
  it("never writes the token through a symlink", async () => {
    const target = path.join(dir, "elsewhere")
    await fs.writeFile(target, "unrelated\n", { mode: 0o644 })
    await fs.mkdir(path.dirname(credentialsFile), { recursive: true })
    await fs.symlink(target, credentialsFile)

    await writeCredentialsFile({ url: "https://syrus.example.com", token: "secret-token" })

    expect(await fs.readFile(target, "utf8")).toBe("unrelated\n")
    const info = await fs.lstat(credentialsFile)
    expect(info.isSymbolicLink()).toBe(false)
    expect(info.mode & 0o777).toBe(0o600)
    expect(await readCredentialsFile()).toContain("token=secret-token")
  })

  it("never leaves the token in a file others can read", async () => {
    await fs.mkdir(path.dirname(credentialsFile), { recursive: true })
    await fs.writeFile(credentialsFile, "url=x\ntoken=old\n", { mode: 0o644 })
    await fs.chmod(credentialsFile, 0o644)
    const before = await fs.stat(credentialsFile)

    await writeCredentialsFile({ url: "https://syrus.example.com", token: "secret-token" })

    const after = await fs.stat(credentialsFile)
    expect(after.ino).not.toBe(before.ino)
    expect(after.mode & 0o777).toBe(0o600)
    const leftovers = (await fs.readdir(path.dirname(credentialsFile))).filter((name) => name !== "credentials")
    expect(leftovers).toEqual([])
  })
})
