import fs from "node:fs/promises"
import path from "node:path"
import { currentStackIdentity } from "./settings.js"

// ~/.syrus/credentials is the shared Bearer-auth home for the tray app and
// the Syrus CLI — url=/token= lines, 0600. This module owns the file format
// and I/O; the caller owns caching, server validation, and side effects.
// Channel-aware: the test build reads/writes ~/.syrus/credentials.test, the
// same file the `syrus-test` CLI targets.
export type Credentials = {
  url: string
  token: string
}

export const credentialsPath = () => currentStackIdentity().credentialsFile

export const validateCredentialsShape = (credentials: Credentials) => {
  if (credentials.url.trim() === "" || credentials.token.trim() === "") {
    throw new Error("Syrus instance URL and API token are required.")
  }
}

const trimWrappingQuotes = (value: string) => value.replace(/^["']+|["']+$/g, "")

export const parseCredentials = (contents: string): Credentials => {
  const credentials: Credentials = { url: "", token: "" }

  for (const rawLine of contents.split(/\r?\n/)) {
    const line = rawLine.trim()
    if (line === "" || line.startsWith("#")) {
      continue
    }

    const separatorIndex = line.indexOf("=")
    if (separatorIndex === -1) {
      throw new Error(`Invalid credentials line: ${line}`)
    }

    const key = line.slice(0, separatorIndex).trim()
    const value = trimWrappingQuotes(line.slice(separatorIndex + 1).trim())

    if (key === "url") {
      credentials.url = value
    } else if (key === "token") {
      credentials.token = value
    }
  }

  validateCredentialsShape(credentials)
  return credentials
}

// Returns null when the file does not exist; throws on other I/O errors.
export const readCredentialsFile = async (): Promise<string | null> => {
  try {
    return await fs.readFile(credentialsPath(), "utf8")
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      return null
    }

    throw error
  }
}

export const writeCredentialsFile = async (credentials: Credentials) => {
  const filePath = credentialsPath()
  await fs.mkdir(path.dirname(filePath), { recursive: true, mode: 0o700 })
  await fs.chmod(path.dirname(filePath), 0o700)
  // Write a fresh 0600 file beside the path and rename it over the path.
  // Writing the path directly followed a symlink into its target, and kept a
  // pre-existing loose file's mode while it held the new token (writeFile's
  // mode applies only on create). The rename replaces the path itself and is
  // atomic, matching the CLI's SaveCredentials.
  const tempPath = path.join(
    path.dirname(filePath),
    `.credentials-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2)}`
  )
  try {
    const handle = await fs.open(tempPath, "wx", 0o600)
    try {
      await handle.chmod(0o600)
      await handle.writeFile(`url=${credentials.url}\ntoken=${credentials.token}\n`)
      await handle.sync()
    } finally {
      await handle.close()
    }
    await fs.rename(tempPath, filePath)
  } finally {
    await fs.rm(tempPath, { force: true })
  }
}

export const deleteCredentialsFile = async () => {
  try {
    await fs.unlink(credentialsPath())
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
      throw error
    }
  }
}
