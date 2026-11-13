export const EXPECTED_API_VERSION = 1

export type ApiEnvelope = {
  v?: number
}

export class ApiVersionError extends Error {}

export const checkApiVersion = (payload: unknown) => {
  if (!payload || typeof payload !== "object") return

  const version = (payload as ApiEnvelope).v
  if (typeof version === "number" && version !== EXPECTED_API_VERSION) {
    throw new ApiVersionError(`Syrus API version ${version} is not supported by this app (expected ${EXPECTED_API_VERSION}); update Syrus Desktop.`)
  }
}

export const readApiJson = async <T>(response: Response): Promise<T> => {
  const payload = (await response.json()) as T
  checkApiVersion(payload)
  return payload
}

export const checkJsonResponseVersion = async (response: Response): Promise<void> => {
  if (response.status === 204) return
  await readApiJson(response)
}
