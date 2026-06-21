export type ApiErrorPayload = {
  error?: {
    code?: string
    message?: string
  }
}

export class ApiError extends Error {
  readonly status: number
  readonly code?: string

  constructor(message: string, options: { status: number; code?: string }) {
    super(message)
    this.name = "ApiError"
    this.status = options.status
    this.code = options.code
  }
}

export async function getJson<T>(path: string, options: { signal?: AbortSignal } = {}): Promise<T> {
  const response = await fetch(path, {
    credentials: "same-origin",
    headers: {
      Accept: "application/json"
    },
    signal: options.signal
  })

  if (response.status === 401) {
    window.location.assign("/session/new")
  }

  if (!response.ok) {
    const payload = await readErrorPayload(response)
    throw new ApiError(payload.error?.message || `Request failed with ${response.status}`, {
      status: response.status,
      code: payload.error?.code
    })
  }

  if (response.status === 204) return undefined as T

  return response.json() as Promise<T>
}

export async function postJson<T>(path: string, body?: unknown): Promise<T> {
  return writeJson<T>(path, "POST", body)
}

export async function patchJson<T>(path: string, body?: unknown): Promise<T> {
  return writeJson<T>(path, "PATCH", body)
}

export async function deleteJson<T>(path: string): Promise<T> {
  return writeJson<T>(path, "DELETE")
}

export async function postForm<T>(path: string, body: FormData): Promise<T> {
  const headers: Record<string, string> = {
    Accept: "application/json"
  }
  const csrfToken = document.querySelector<HTMLMetaElement>("meta[name='csrf-token']")?.content

  if (csrfToken) {
    headers["X-CSRF-Token"] = csrfToken
  }

  const response = await fetch(path, {
    method: "POST",
    credentials: "same-origin",
    headers,
    body
  })

  if (response.status === 401) {
    window.location.assign("/session/new")
  }

  if (!response.ok) {
    const payload = await readErrorPayload(response)
    throw new ApiError(payload.error?.message || `Request failed with ${response.status}`, {
      status: response.status,
      code: payload.error?.code
    })
  }

  if (response.status === 204) return undefined as T

  return response.json() as Promise<T>
}

async function writeJson<T>(path: string, method: "POST" | "PATCH" | "DELETE", body?: unknown): Promise<T> {
  const headers: Record<string, string> = {
    Accept: "application/json"
  }
  const csrfToken = document.querySelector<HTMLMetaElement>("meta[name='csrf-token']")?.content

  if (csrfToken) {
    headers["X-CSRF-Token"] = csrfToken
  }
  if (body !== undefined) {
    headers["Content-Type"] = "application/json"
  }

  const response = await fetch(path, {
    method,
    credentials: "same-origin",
    headers,
    body: body === undefined ? undefined : JSON.stringify(body)
  })

  if (response.status === 401) {
    window.location.assign("/session/new")
  }

  if (!response.ok) {
    const payload = await readErrorPayload(response)
    throw new ApiError(payload.error?.message || `Request failed with ${response.status}`, {
      status: response.status,
      code: payload.error?.code
    })
  }

  if (response.status === 204) return undefined as T

  return response.json() as Promise<T>
}

async function readErrorPayload(response: Response): Promise<ApiErrorPayload> {
  try {
    return (await response.json()) as ApiErrorPayload
  } catch (_error) {
    return {}
  }
}
