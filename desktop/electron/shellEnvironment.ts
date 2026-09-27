import { execFile } from "node:child_process"
import os from "node:os"
import { promisify } from "node:util"

const execFileAsync = promisify(execFile)
const ENV_MARKER = "__SYRUS_LOGIN_ENV__"
const ENV_MARKER_WITH_SEPARATOR = `${ENV_MARKER}\0`

export const parseLoginShellEnvironment = (
  output: string,
  fallback: NodeJS.ProcessEnv
): NodeJS.ProcessEnv => {
  const markerIndex = output.lastIndexOf(ENV_MARKER_WITH_SEPARATOR)
  if (markerIndex < 0) return { ...fallback }

  const environment = { ...fallback }
  const payload = output.slice(markerIndex + ENV_MARKER_WITH_SEPARATOR.length)
  for (const entry of payload.split("\0")) {
    const separator = entry.indexOf("=")
    if (separator <= 0) continue
    environment[entry.slice(0, separator)] = entry.slice(separator + 1)
  }
  return environment
}

export const resolveLoginShellEnvironment = async (
  fallback: NodeJS.ProcessEnv = process.env
): Promise<NodeJS.ProcessEnv> => {
  if (process.platform === "win32") return { ...fallback }

  const shell = fallback.SHELL || "/bin/sh"
  try {
    const { stdout } = await execFileAsync(
      shell,
      ["-ilc", `printf '${ENV_MARKER}\\0'; /usr/bin/env -0`],
      {
        encoding: "utf8",
        env: fallback,
        maxBuffer: 4 * 1024 * 1024,
        timeout: 10_000,
        windowsHide: true
      }
    )
    return parseLoginShellEnvironment(stdout, fallback)
  } catch {
    return { ...fallback }
  }
}

let cachedEnvironment: Promise<NodeJS.ProcessEnv> | null = null

export const desktopCommandEnvironment = (): Promise<NodeJS.ProcessEnv> => {
  cachedEnvironment ??= resolveLoginShellEnvironment({
    ...process.env,
    HOME: process.env.HOME || os.homedir()
  })
  return cachedEnvironment
}
