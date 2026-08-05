import { ApiError, postJson } from "./client"

export type SpeechToTextTranscript = {
  text: string
  source: "backend_batch"
  confidence: number | null
}

export type SpeechToTextStreamConfig = {
  stream: {
    transport: "action_cable"
    channel: "ChatDictationChannel"
    chat_session_id: number
    events: string[]
    fallback?: {
      mode: "backend_batch"
      buffered_audio_required: boolean
      endpoint: string
    }
  }
}

export const MAX_TRANSCRIPTION_DURATION_SECONDS = 120
export const MAX_TRANSCRIPTION_BYTES = 10 * 1024 * 1024
export const TRANSCRIPTION_AUDIO_CONTENT_TYPES = [
  "audio/webm",
  "audio/mp4",
  "audio/mpeg",
  "audio/wav",
  "audio/x-wav",
  "audio/ogg"
]

export function isTranscriptionAudioFile(file: File): boolean {
  return TRANSCRIPTION_AUDIO_CONTENT_TYPES.some((type) => file.type === type || file.type.startsWith(`${type};`))
}

export function transcribeChatAudio(input: {
  chatSessionId: number
  file: File | Blob
  filename: string
  durationSeconds?: number | null
  language?: string
  prompt?: string
  signal?: AbortSignal
}): Promise<{ transcript: SpeechToTextTranscript }> {
  return new Promise((resolve, reject) => {
    const form = new FormData()
    form.append("file", input.file, input.filename)
    if (input.durationSeconds) form.append("duration_seconds", String(input.durationSeconds))
    if (input.language) form.append("language", input.language)
    if (input.prompt) form.append("prompt", input.prompt)

    const xhr = new XMLHttpRequest()
    xhr.open("POST", `/api/v1/app/chats/${encodeURIComponent(String(input.chatSessionId))}/speech_to_text`)
    xhr.responseType = "json"
    xhr.setRequestHeader("Accept", "application/json")

    const csrf = document.querySelector<HTMLMetaElement>("meta[name=csrf-token]")?.content
    if (csrf) xhr.setRequestHeader("X-CSRF-Token", csrf)

    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        resolve(xhr.response as { transcript: SpeechToTextTranscript })
      } else {
        const payload = xhr.response as { error?: { code?: string; message?: string } } | null
        reject(new ApiError(payload?.error?.message || `Transcription failed with ${xhr.status}`, {
          status: xhr.status,
          code: payload?.error?.code
        }))
      }
    }
    xhr.onerror = () => reject(new ApiError("Transcription failed - check your connection.", { status: 0 }))
    xhr.onabort = () => reject(new DOMException("aborted", "AbortError"))
    input.signal?.addEventListener("abort", () => xhr.abort())

    xhr.send(form)
  })
}

export function startChatAudioStream(path: string): Promise<SpeechToTextStreamConfig> {
  return postJson<SpeechToTextStreamConfig>(path)
}
