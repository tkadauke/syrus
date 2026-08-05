import { afterEach, describe, expect, it, vi } from "vitest"
import { ApiError } from "./client"
import {
  isTranscriptionAudioFile,
  MAX_TRANSCRIPTION_BYTES,
  MAX_TRANSCRIPTION_DURATION_SECONDS,
  TRANSCRIPTION_AUDIO_CONTENT_TYPES,
  transcribeChatAudio
} from "./speechToText"

describe("speech-to-text upload gates", () => {
  it("caps duration at 120 seconds, matching the backend", () => {
    expect(MAX_TRANSCRIPTION_DURATION_SECONDS).toBe(120)
  })

  it("caps size at 10 MB, matching the backend", () => {
    expect(MAX_TRANSCRIPTION_BYTES).toBe(10_485_760)
  })

  it("accepts recorder-friendly audio content types", () => {
    expect(TRANSCRIPTION_AUDIO_CONTENT_TYPES).toEqual([
      "audio/webm",
      "audio/mp4",
      "audio/mpeg",
      "audio/wav",
      "audio/x-wav",
      "audio/ogg"
    ])
    expect(isTranscriptionAudioFile(new File([""], "dictation.webm", { type: "audio/webm;codecs=opus" }))).toBe(true)
    expect(isTranscriptionAudioFile(new File([""], "notes.txt", { type: "text/plain" }))).toBe(false)
  })
})

describe("transcribeChatAudio", () => {
  afterEach(() => {
    vi.unstubAllGlobals()
    document.head.innerHTML = ""
  })

  it("uploads multipart audio and resolves the transcript", async () => {
    const requests: FakeXMLHttpRequest[] = []
    vi.stubGlobal("XMLHttpRequest", fakeXMLHttpRequestClass(requests))
    document.head.innerHTML = '<meta name="csrf-token" content="csrf-token">'

    const promise = transcribeChatAudio({
      chatSessionId: 42,
      file: new Blob(["audio"], { type: "audio/webm" }),
      filename: "dictation.webm",
      durationSeconds: 8,
      language: "en"
    })

    expect(requests[0].method).toBe("POST")
    expect(requests[0].url).toBe("/api/v1/app/chats/42/speech_to_text")
    expect(requests[0].headers).toMatchObject({
      Accept: "application/json",
      "X-CSRF-Token": "csrf-token"
    })
    expect(requests[0].body).toBeInstanceOf(FormData)

    requests[0].respond(200, { transcript: { text: "hello", source: "backend_batch", confidence: null } })

    await expect(promise).resolves.toEqual({
      transcript: { text: "hello", source: "backend_batch", confidence: null }
    })
  })

  it("rejects with the backend error envelope", async () => {
    const requests: FakeXMLHttpRequest[] = []
    vi.stubGlobal("XMLHttpRequest", fakeXMLHttpRequestClass(requests))

    const promise = transcribeChatAudio({
      chatSessionId: 42,
      file: new Blob(["audio"], { type: "audio/webm" }),
      filename: "dictation.webm"
    })
    requests[0].respond(502, { error: { code: "speech_to_text_transcription_failed", message: "model unavailable" } })

    await expect(promise).rejects.toMatchObject(
      new ApiError("model unavailable", { status: 502, code: "speech_to_text_transcription_failed" })
    )
  })
})

class FakeXMLHttpRequest {
  method = ""
  url = ""
  responseType = ""
  response: unknown = null
  status = 0
  headers: Record<string, string> = {}
  body: XMLHttpRequestBodyInit | null = null
  upload = {}
  onload: (() => void) | null = null
  onerror: (() => void) | null = null
  onabort: (() => void) | null = null

  open(method: string, url: string) {
    this.method = method
    this.url = url
  }

  setRequestHeader(name: string, value: string) {
    this.headers[name] = value
  }

  send(body: XMLHttpRequestBodyInit | null) {
    this.body = body
  }

  abort() {
    this.onabort?.()
  }

  respond(status: number, response: unknown) {
    this.status = status
    this.response = response
    this.onload?.()
  }
}

function fakeXMLHttpRequestClass(requests: FakeXMLHttpRequest[]) {
  return class extends FakeXMLHttpRequest {
    constructor() {
      super()
      requests.push(this)
    }
  }
}
