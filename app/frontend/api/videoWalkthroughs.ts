import { ApiError, postJson } from "./client"

// Walkthrough videos upload as real multipart (100-500MB) — NOT the base64
// JSON path chat images use. XHR instead of the client's postForm because
// only XHR exposes upload progress events; everything else (CSRF meta tag,
// Accept header, the {error:{code,message}} envelope) mirrors api/client.ts.

export type VideoWalkthrough = {
  id: number
  chat_session_id: number
  state: "uploaded" | "analyzing" | "analyzed" | "failed"
  title: string
  duration_seconds: number | null
  byte_size: number
  error_message: string | null
  created_at: string
}

// Mirror of ChatVideoWalkthrough model gates — keep in sync (pinned by
// spec/frontend parity assertions in videoWalkthrough vitest).
export const MAX_WALKTHROUGH_DURATION_SECONDS = 15 * 60
export const MAX_WALKTHROUGH_BYTES = 500 * 1024 * 1024
export const WALKTHROUGH_CONTENT_TYPES = ["video/webm", "video/mp4", "video/quicktime"]

export function isWalkthroughVideoFile(file: File): boolean {
  return WALKTHROUGH_CONTENT_TYPES.some((type) => file.type === type || file.type.startsWith(`${type};`))
}

// Measure a dragged-in file's duration in the browser (there is no ffmpeg
// server-side; Gemini decodes the video itself, so this is the UX gate).
// Resolves null when the browser can't read metadata (still uploadable —
// the analysis will reveal problems).
export function measureVideoDuration(file: File): Promise<number | null> {
  return new Promise((resolve) => {
    const video = document.createElement("video")
    const url = URL.createObjectURL(file)
    const cleanup = () => URL.revokeObjectURL(url)
    video.preload = "metadata"
    video.onloadedmetadata = () => {
      cleanup()
      const duration = Number.isFinite(video.duration) ? Math.round(video.duration) : null
      resolve(duration && duration > 0 ? duration : null)
    }
    video.onerror = () => {
      cleanup()
      resolve(null)
    }
    video.src = url
  })
}

export function uploadVideoWalkthrough(input: {
  chatSessionId: number
  file: File | Blob
  filename: string
  durationSeconds: number | null
  note?: string
  onProgress?: (percent: number) => void
  signal?: AbortSignal
}): Promise<{ video_walkthrough: VideoWalkthrough }> {
  return new Promise((resolve, reject) => {
    const form = new FormData()
    form.append("file", input.file, input.filename)
    if (input.durationSeconds) form.append("duration_seconds", String(input.durationSeconds))
    if (input.note) form.append("note", input.note)

    const xhr = new XMLHttpRequest()
    xhr.open("POST", `/api/v1/app/chats/${encodeURIComponent(String(input.chatSessionId))}/video_walkthroughs`)
    xhr.responseType = "json"
    xhr.setRequestHeader("Accept", "application/json")

    const csrf = document.querySelector<HTMLMetaElement>("meta[name=csrf-token]")?.content
    if (csrf) xhr.setRequestHeader("X-CSRF-Token", csrf)

    xhr.upload.onprogress = (event) => {
      if (event.lengthComputable && input.onProgress) {
        input.onProgress(Math.round((event.loaded / event.total) * 100))
      }
    }
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        resolve(xhr.response as { video_walkthrough: VideoWalkthrough })
      } else {
        const payload = xhr.response as { error?: { code?: string; message?: string } } | null
        reject(new ApiError(payload?.error?.message || `Upload failed with ${xhr.status}`, {
          status: xhr.status,
          code: payload?.error?.code
        }))
      }
    }
    xhr.onerror = () => reject(new ApiError("Upload failed — check your connection.", { status: 0 }))
    xhr.onabort = () => reject(new DOMException("aborted", "AbortError"))
    input.signal?.addEventListener("abort", () => xhr.abort())

    xhr.send(form)
  })
}

// The template comes from the chat payload, contributed by the plugin that
// owns the route -- core does not know the URL, which is what keeps this file
// on the right side of the plugin boundary.
export function retryVideoWalkthrough(pathTemplate: string, id: number): Promise<{ video_walkthrough: VideoWalkthrough }> {
  return postJson<{ video_walkthrough: VideoWalkthrough }>(
    pathTemplate.replace(":id", encodeURIComponent(String(id)))
  )
}
