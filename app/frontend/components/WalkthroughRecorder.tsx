import { useCallback, useEffect, useRef, useState } from "react"
import { MAX_WALKTHROUGH_DURATION_SECONDS } from "../api/videoWalkthroughs"
import {
  annotationBridge,
  recorderHudBridge,
  type AnnotationHoldFailureReason,
  type SyrusAnnotationBridge,
  type SyrusRecorderHudBridge,
  type SyrusRecorderHudState
} from "../lib/desktopShell"

// --- red-pen annotation helpers (desktop shell only) --------------------
//
// The desktop shell exposes window.syrusShell.annotation: a transparent
// always-on-top overlay the recorder's full-screen capture picks up
// incidentally. Draw mode is PRESS-TO-ARM, AUTO-RELEASE: tapping the global
// shortcut arms the pen, and it drops back to click-through on its own once the
// user pauses (so the app under test stays interactive except while actively
// marking). onModeChanged pushes every arm/auto-release transition, so the HUD
// just reflects `drawing` — the shell owns the overlay + the auto-release logic.
// These pure helpers drive the recording HUD's affordances.

// The draw-mode accelerator, formatted for display. macOS shows the glyphs it
// uses everywhere (⌘⇧A); every other platform spells it out (Ctrl+Shift+A).
export function isMacPlatform(
  ua: string = typeof navigator !== "undefined" ? navigator.userAgent : ""
): boolean {
  return /Mac|iPhone|iPad|iPod/.test(ua)
}

export function annotationShortcutLabel(mac: boolean = isMacPlatform()): string {
  return mac ? "⌘⇧A" : "Ctrl+Shift+A"
}

// The modifier the native HOLD-to-draw hook watches (Ctrl on both platforms;
// shown as the bare ⌃ glyph on macOS — the hint must stay tiny — and spelled
// out where the glyph is unfamiliar).
export function annotationHoldLabel(mac: boolean = isMacPlatform()): string {
  return mac ? "⌃" : "Ctrl"
}

// Which idle hint the recording HUD shows for the pen: HOLD when the native
// hook is live; the Accessibility nudge when hold failed ONLY for the macOS
// permission (the tap fallback still works, and granting the permission
// upgrades the next recording to hold); the plain TAP hint otherwise.
export type AnnotationIdleHintKind = "hold" | "accessibility" | "tap"

export function annotationIdleHintKind(
  hold: boolean,
  reason?: AnnotationHoldFailureReason | null
): AnnotationIdleHintKind {
  if (hold) return "hold"
  if (reason === "no-accessibility") return "accessibility"
  return "tap"
}

// The overlay is only composited into the recording when the user shares a
// WHOLE screen ("monitor"). The overlay spans every display, so sharing ANY
// monitor works — no note. Sharing a single window or browser tab excludes the
// always-on-top overlay, so the recorder nudges the user with a note. A null /
// unknown surface (older browsers don't report it) is treated as fine — no note
// rather than a note that might be wrong.
export function shouldShowAnnotationSurfaceNote(
  annotationAvailable: boolean,
  displaySurface: string | null
): boolean {
  if (!annotationAvailable) return false
  return displaySurface === "window" || displaySurface === "browser"
}

// In-chat screen recording for walkthrough videos. getDisplayMedia gives the
// browser's native Meet-style picker; the mic rides along as a separate
// getUserMedia track so the user's narration is captured (Gemini ingests the
// audio track natively — narration is half the signal). The recorder gates
// GENTLY: a visible countdown with a warning at T-60s and a friendly
// auto-stop at the 15:00 cap, never a surprise error.

// Codec preference: VP9 handles static UI + text well at low bitrates and is
// always available in Chrome/Electron (software encoder). MP4/H.264 exists
// only where an OS encoder does — probe, never assume. Exported for tests.
export const RECORDER_MIME_CANDIDATES = [
  "video/webm;codecs=vp9,opus",
  "video/webm;codecs=vp8,opus",
  "video/webm",
  "video/mp4"
]

export function pickRecorderMimeType(
  isSupported: (type: string) => boolean = (type) =>
    typeof MediaRecorder !== "undefined" && MediaRecorder.isTypeSupported(type)
): string | null {
  return RECORDER_MIME_CANDIDATES.find((candidate) => isSupported(candidate)) ?? null
}

// Gemini samples video at 1 fps, so >15 fps is wasted bytes; 1080p cap +
// 2.5 Mbps yields ~20 MB/min → a full 15:00 recording ≈ 300 MB, inside the
// 500 MB upload gate with margin.
export const RECORDER_VIDEO_CONSTRAINTS: MediaTrackConstraints = {
  width: { max: 1920 },
  height: { max: 1080 },
  frameRate: { ideal: 10, max: 15 }
}
export const RECORDER_VIDEO_BITS_PER_SECOND = 2_500_000
export const RECORDER_AUDIO_BITS_PER_SECOND = 128_000
export const RECORDER_WARNING_SECONDS = MAX_WALKTHROUGH_DURATION_SECONDS - 60

export function formatClock(totalSeconds: number): string {
  const clamped = Math.max(0, Math.floor(totalSeconds))
  const minutes = Math.floor(clamped / 60)
  const seconds = clamped % 60
  return `${minutes}:${String(seconds).padStart(2, "0")}`
}

export type RecordingResult = {
  blob: Blob
  mimeType: string
  durationSeconds: number
}

type RecorderState =
  | { phase: "idle" }
  | { phase: "starting" }
  | { phase: "recording"; startedAt: number; micLive: boolean }
  | { phase: "error"; message: string }

export function useWalkthroughRecorder({
  onFinished,
  // The desktop shell's red-pen surface, injectable for tests. Defaults to the
  // live bridge (null in a plain browser → no annotation UI, recorder unchanged).
  annotation
}: {
  onFinished: (result: RecordingResult) => void
  annotation?: SyrusAnnotationBridge | null
}) {
  const [state, setState] = useState<RecorderState>({ phase: "idle" })
  const [elapsed, setElapsed] = useState(0)
  // Which surface the user chose to share, read once per recording from the
  // display track. Drives the "share your whole screen to see marks" note.
  const [displaySurface, setDisplaySurface] = useState<string | null>(null)
  // Live draw-mode flag, pushed from the shell over onModeChanged, so the HUD
  // can reflect whether the pen is currently armed.
  const [drawing, setDrawing] = useState(false)
  // Whether the desktop shell's red-pen overlay is actually live for THIS
  // recording — set from enable()'s resolved boolean, not merely bridge
  // presence. A shell that reports the overlay/shortcut unavailable (enable →
  // false) must not advertise a dead ⌘⇧A hint, so the HUD gates on this.
  const [annotationReady, setAnnotationReady] = useState(false)
  // Whether the live annotation surface is the native HOLD-to-draw hook (Ctrl
  // held → armed) vs the TAP fallback (⌘⇧A), so the HUD shows the right hint.
  const [annotationHold, setAnnotationHold] = useState(false)
  // WHY hold mode could not start (null when it did, or when nothing reported
  // a reason). "no-accessibility" drives the HUD's "grant Accessibility" nudge.
  const [annotationReason, setAnnotationReason] = useState<AnnotationHoldFailureReason | null>(null)
  const recorderRef = useRef<MediaRecorder | null>(null)
  const streamsRef = useRef<MediaStream[]>([])
  const chunksRef = useRef<Blob[]>([])
  const tickRef = useRef<ReturnType<typeof setInterval> | null>(null)
  const startedAtRef = useRef(0)
  const finishedRef = useRef(false)
  // Resolve the bridge once — a plain browser has none, and re-reading it per
  // render would defeat the injectable test seam.
  const annotationRef = useRef<SyrusAnnotationBridge | null>(annotation ?? annotationBridge())
  const annotationUnsubscribeRef = useRef<(() => void) | null>(null)

  const cleanup = useCallback(() => {
    if (tickRef.current) {
      clearInterval(tickRef.current)
      tickRef.current = null
    }
    streamsRef.current.forEach((stream) => stream.getTracks().forEach((track) => track.stop()))
    streamsRef.current = []
    recorderRef.current = null
    // Tear the annotation overlay + global shortcut down on EVERY exit path
    // (stop, discard, natural end, error, unmount) — disable() is idempotent,
    // so a recording that never enabled it is a harmless no-op.
    if (annotationUnsubscribeRef.current) {
      annotationUnsubscribeRef.current()
      annotationUnsubscribeRef.current = null
    }
    annotationRef.current?.disable().catch(() => {})
    setDrawing(false)
    setAnnotationReady(false)
    setAnnotationHold(false)
    setAnnotationReason(null)
    setDisplaySurface(null)
  }, [])

  const stop = useCallback((options: { discard?: boolean } = {}) => {
    const recorder = recorderRef.current
    if (!recorder || finishedRef.current) {
      cleanup()
      setState({ phase: "idle" })
      setElapsed(0)
      return
    }

    finishedRef.current = true
    if (options.discard) {
      recorder.ondataavailable = null
      recorder.onstop = null
      try {
        recorder.stop()
      } catch {
        // already inactive — fine
      }
      cleanup()
      setState({ phase: "idle" })
      setElapsed(0)
      return
    }

    try {
      recorder.stop() // onstop assembles + delivers the result
    } catch {
      cleanup()
      setState({ phase: "error", message: "Recording could not be finalized." })
    }
  }, [cleanup])

  const start = useCallback(async () => {
    if (state.phase === "recording" || state.phase === "starting") return

    setState({ phase: "starting" })
    finishedRef.current = false
    chunksRef.current = []

    let display: MediaStream
    try {
      display = await navigator.mediaDevices.getDisplayMedia({
        video: RECORDER_VIDEO_CONSTRAINTS,
        audio: false
      })
    } catch {
      // User dismissed the picker (or the platform denied capture) — back to
      // idle silently; the picker itself was the confirmation surface.
      setState({ phase: "idle" })
      return
    }

    // What did they choose to share? "monitor" composites the always-on-top
    // annotation overlay; "window"/"browser" excludes it (the HUD nudges them).
    // getSettings is optional (older engines, test fakes) — never let reading
    // it crash the recording.
    const videoTrack = display.getVideoTracks()[0]
    const settings = typeof videoTrack?.getSettings === "function" ? videoTrack.getSettings() : undefined
    const surface = (settings as (MediaTrackSettings & { displaySurface?: string }) | undefined)?.displaySurface
    setDisplaySurface(typeof surface === "string" ? surface : null)

    // Arm the red-pen overlay (desktop shell only). An overlay failure must
    // never block the recording, so enable() rejections are swallowed and the
    // recorder proceeds without annotation. enable() RESOLVES { available, hold }
    // — whether a surface came up, and whether it's the native HOLD hook or the
    // TAP fallback; only then does the HUD advertise the hint (annotationReady),
    // with the wording matching the mode (annotationHold). The finishedRef guard
    // drops a late resolution that lands after the recording already stopped.
    const annotationApi = annotationRef.current
    if (annotationApi) {
      annotationApi
        .enable()
        .then((result) => {
          if (finishedRef.current) return
          setAnnotationReady(result.available === true)
          setAnnotationHold(result.hold === true)
          // Why hold could not start (undefined on success / old shells) —
          // "no-accessibility" turns the idle hint into the grant-permission
          // nudge while the tap fallback stays advertised and functional.
          setAnnotationReason(result.hold === true ? null : (result.reason ?? null))
        })
        .catch(() => {
          if (!finishedRef.current) {
            setAnnotationReady(false)
            setAnnotationHold(false)
            setAnnotationReason(null)
          }
        })
      annotationUnsubscribeRef.current = annotationApi.onModeChanged((armed) => setDrawing(armed))
    }

    // Narration mic — requested AFTER the display picker so a mic denial
    // never blocks the recording; a walkthrough without narration is still
    // analyzable (Gemini flags ambiguities as open questions).
    let micLive = false
    let mic: MediaStream | null = null
    try {
      mic = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true }
      })
      micLive = true
    } catch {
      mic = null
    }

    const tracks = [ ...display.getVideoTracks(), ...(mic ? mic.getAudioTracks() : []) ]
    const combined = new MediaStream(tracks)
    streamsRef.current = [ display, ...(mic ? [mic] : []) ]

    const mimeType = pickRecorderMimeType()
    let recorder: MediaRecorder
    try {
      recorder = new MediaRecorder(combined, {
        ...(mimeType ? { mimeType } : {}),
        videoBitsPerSecond: RECORDER_VIDEO_BITS_PER_SECOND,
        audioBitsPerSecond: RECORDER_AUDIO_BITS_PER_SECOND
      })
    } catch {
      cleanup()
      setState({ phase: "error", message: "This browser cannot record the screen. Drag a video file in instead." })
      return
    }

    recorder.ondataavailable = (event) => {
      if (event.data.size > 0) chunksRef.current.push(event.data)
    }
    recorder.onstop = () => {
      const durationSeconds = Math.max(1, Math.round((Date.now() - startedAtRef.current) / 1000))
      const type = recorder.mimeType || mimeType || "video/webm"
      const blob = new Blob(chunksRef.current, { type: type.split(";")[0] })
      cleanup()
      setState({ phase: "idle" })
      setElapsed(0)
      onFinished({ blob, mimeType: type.split(";")[0], durationSeconds })
    }

    // Ending the share from the browser's own "Stop sharing" bar must finish
    // the recording, not orphan it.
    display.getVideoTracks()[0]?.addEventListener("ended", () => {
      if (!finishedRef.current && recorderRef.current) {
        finishedRef.current = true
        recorderRef.current.stop()
      }
    })

    recorderRef.current = recorder
    startedAtRef.current = Date.now()
    recorder.start(1_000) // 1s timeslices so a crash loses at most a second
    setElapsed(0)
    setState({ phase: "recording", startedAt: startedAtRef.current, micLive })

    tickRef.current = setInterval(() => {
      const seconds = Math.round((Date.now() - startedAtRef.current) / 1000)
      setElapsed(seconds)
      if (seconds >= MAX_WALKTHROUGH_DURATION_SECONDS && !finishedRef.current && recorderRef.current) {
        // The gentle gate: at 15:00 the recording completes as a SUCCESS.
        finishedRef.current = true
        recorderRef.current.stop()
      }
    }, 500)
  }, [state.phase, cleanup, onFinished])

  useEffect(() => () => cleanup(), [cleanup])

  return {
    state,
    elapsed,
    start,
    stop,
    // Whether the desktop shell's red-pen overlay is LIVE for this recording
    // (enable() resolved true) — drives the HUD hint. False in a plain browser,
    // an older shell, or when the overlay/shortcut couldn't be created, so the
    // HUD never advertises an affordance that can't work.
    annotationAvailable: annotationReady,
    // Whether the live annotation surface is the native HOLD-to-draw hook (vs the
    // tap fallback) — the HUD hint reads "hold Ctrl" vs "tap ⌘⇧A" accordingly.
    annotationHold,
    // Why hold mode could not start (null when it did). "no-accessibility"
    // makes the HUD nudge the user to grant the macOS permission.
    annotationReason,
    // The chosen capture surface, for the "share your whole screen" nudge.
    displaySurface,
    // Live draw-mode flag from the overlay.
    drawing
  }
}

// Drives the desktop shell's FLOATING recording HUD — a separate always-on-top,
// draggable window (window.syrusShell.recorderHud) — so the recording controls
// live OUTSIDE the Syrus web-app window and stay reachable while the user
// demonstrates another app. Shows it on record start, pushes `state` each tick,
// hides it on stop; wires the HUD's Stop/Discard buttons back to onStop/onDiscard.
// Returns whether the native HUD is active — false in a plain browser or older
// shell, where the caller renders the in-page WalkthroughRecorderHUD instead.
export function useNativeRecorderHud({
  recording,
  state,
  onStop,
  onDiscard,
  bridge
}: {
  recording: boolean
  state: SyrusRecorderHudState
  onStop: () => void
  onDiscard: () => void
  bridge?: SyrusRecorderHudBridge | null
}): boolean {
  const bridgeRef = useRef<SyrusRecorderHudBridge | null>(bridge ?? recorderHudBridge())
  // Latest callbacks, so the once-subscribed onAction always calls the current
  // stop/discard without re-subscribing.
  const handlersRef = useRef({ onStop, onDiscard })
  handlersRef.current = { onStop, onDiscard }
  const shownRef = useRef(false)
  // The last state serialized to the HUD, so an IPC `update` fires only when the
  // displayed state actually changes — NOT on every Compose re-render (typing in
  // the composer while recording would otherwise spam the HUD window).
  const lastSentRef = useRef<string>("")

  useEffect(() => {
    const activeBridge = bridgeRef.current
    if (!activeBridge) return

    return activeBridge.onAction((kind) => {
      if (kind === "stop") handlersRef.current.onStop()
      else handlersRef.current.onDiscard()
    })
  }, [])

  useEffect(() => {
    const activeBridge = bridgeRef.current
    if (!activeBridge) return

    if (recording) {
      const serialized = JSON.stringify(state)
      if (shownRef.current) {
        if (serialized !== lastSentRef.current) {
          lastSentRef.current = serialized
          void activeBridge.update(state).catch(() => {})
        }
      } else {
        shownRef.current = true
        lastSentRef.current = serialized
        void activeBridge.show(state).catch(() => {})
      }
    } else if (shownRef.current) {
      shownRef.current = false
      lastSentRef.current = ""
      void activeBridge.hide().catch(() => {})
    }
  }, [recording, state])

  // Tear the HUD down on unmount even if the recording flag never flipped back.
  useEffect(
    () => () => {
      if (shownRef.current) {
        shownRef.current = false
        void bridgeRef.current?.hide().catch(() => {})
      }
    },
    []
  )

  return bridgeRef.current != null
}

// Analysis can run for minutes; a single static line ("Gemini is watching…")
// reads as frozen. This cycles through a handful of reassuring hints so the
// wait feels alive. Kept pure — callers pass already-translated strings, and
// the interval is injectable for tests. Honors prefers-reduced-motion by
// holding on the first message instead of animating.
export const ANALYZING_HINT_INTERVAL_MS = 4_500

function prefersReducedMotion(): boolean {
  return (
    typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches
  )
}

export function useRotatingMessage(
  messages: string[],
  intervalMs: number = ANALYZING_HINT_INTERVAL_MS
): string {
  const [index, setIndex] = useState(0)

  useEffect(() => {
    // Nothing to rotate through (0 or 1 message), or the user asked for less
    // motion — hold on the first message.
    if (messages.length <= 1 || prefersReducedMotion()) return
    const id = setInterval(() => {
      setIndex((current) => (current + 1) % messages.length)
    }, intervalMs)
    return () => clearInterval(id)
  }, [messages.length, intervalMs])

  // If the message list shrank between renders, don't index past its end.
  return messages[index % messages.length] ?? messages[0] ?? ""
}

// The rotating "analyzing" line shown on the walkthrough chip. Keeps the
// caller's spinner as a sibling; this renders text only.
export function AnalyzingHint({
  messages,
  intervalMs,
  className
}: {
  messages: string[]
  intervalMs?: number
  className?: string
}) {
  const message = useRotatingMessage(messages, intervalMs)
  return (
    <span aria-live="polite" className={className} data-testid="walkthrough-analyzing-hint">
      {message}
    </span>
  )
}

// The red-pen affordance rendered inside the HUD when the desktop shell offers
// annotation: a deliberately QUIET status — a tiny dot (gray while idle, red
// while drawing) beside a short muted hint ("Hold ⌃ to draw" / "Drawing").
// `drawing` is pushed from the shell's onModeChanged, so it flips back to
// `hint` automatically when draw mode releases. `surfaceNote`, when present,
// warns that marks only show when sharing the whole screen; `accessibilityNote`
// (macOS, hold hook blocked by the Accessibility permission) tells the user
// where in System Settings to grant it — the tap shortcut works meanwhile.
export type WalkthroughAnnotationHud = {
  hint: string
  drawingHint: string
  drawing: boolean
  surfaceNote?: string
  accessibilityNote?: string
}

// The floating HUD while recording: pulsing dot, elapsed clock, remaining
// countdown that turns amber in the final minute, stop + discard controls, and
// (desktop shell only) the red-pen draw-mode hint + capture-surface note.
export function WalkthroughRecorderHUD({
  elapsed,
  micLive,
  onStop,
  onDiscard,
  labels,
  annotation
}: {
  elapsed: number
  micLive: boolean
  onStop: () => void
  onDiscard: () => void
  labels: { recording: string; noMic: string; stop: string; discard: string; windowHint?: string; remaining: (clock: string) => string }
  annotation?: WalkthroughAnnotationHud
}) {
  const remaining = MAX_WALKTHROUGH_DURATION_SECONDS - elapsed
  const finalMinute = elapsed >= RECORDER_WARNING_SECONDS

  return (
    <div
      className="fixed bottom-6 left-1/2 z-50 flex -translate-x-1/2 flex-col items-center gap-2"
      data-testid="walkthrough-recorder-hud-wrap"
    >
      <div
        className="flex items-center gap-3 rounded-full border border-gray-200 bg-white px-4 py-2 shadow-xl dark:border-gray-700 dark:bg-gray-900"
        data-testid="walkthrough-recorder-hud"
        role="status"
      >
        <span aria-hidden="true" className="relative flex h-3 w-3">
          <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-red-400 opacity-75" />
          <span className="relative inline-flex h-3 w-3 rounded-full bg-red-600" />
        </span>
        <span className="text-sm font-medium tabular-nums text-gray-900 dark:text-gray-100">
          {labels.recording} {formatClock(elapsed)}
        </span>
        <span
          className={`text-xs tabular-nums ${finalMinute ? "font-semibold text-amber-600 dark:text-amber-400" : "text-gray-500 dark:text-gray-400"}`}
          data-testid="walkthrough-recorder-remaining"
        >
          {labels.remaining(formatClock(remaining))}
        </span>
        {!micLive ? (
          <span className="text-xs text-amber-600 dark:text-amber-400" title={labels.noMic}>
            {labels.noMic}
          </span>
        ) : null}
        {annotation ? (
          <span
            className={`items-center gap-1.5 text-2xs text-gray-500 dark:text-gray-400 ${
              annotation.drawing ? "inline-flex" : "hidden sm:inline-flex"
            }`}
            data-testid="walkthrough-annotate-hint"
          >
            <span
              aria-hidden="true"
              className={`inline-block h-1.5 w-1.5 flex-none rounded-full ${
                annotation.drawing ? "bg-red-600" : "bg-gray-400 dark:bg-gray-500"
              }`}
              data-testid="walkthrough-annotate-dot"
            />
            {annotation.drawing ? annotation.drawingHint : annotation.hint}
          </span>
        ) : null}
        {labels.windowHint ? (
          <span className="hidden text-xs text-gray-400 sm:inline dark:text-gray-500" data-testid="walkthrough-recorder-window-hint">
            {labels.windowHint}
          </span>
        ) : null}
        <button
          className="rounded-full bg-red-600 px-3 py-1 text-xs font-semibold text-white hover:bg-red-700"
          onClick={onStop}
          type="button"
        >
          {labels.stop}
        </button>
        <button
          className="rounded-full px-2 py-1 text-xs text-gray-500 hover:bg-gray-100 hover:text-gray-700 dark:text-gray-400 dark:hover:bg-gray-800"
          onClick={onDiscard}
          type="button"
        >
          {labels.discard}
        </button>
      </div>
      {annotation?.surfaceNote ? (
        <span
          className="rounded-full border border-amber-200 bg-amber-50 px-3 py-1 text-xs text-amber-700 shadow-sm dark:border-amber-900 dark:bg-amber-950 dark:text-amber-300"
          data-testid="walkthrough-annotate-surface-note"
        >
          {annotation.surfaceNote}
        </span>
      ) : null}
      {annotation?.accessibilityNote ? (
        <span
          className="rounded-full border border-gray-200 bg-white px-3 py-1 text-xs text-gray-600 shadow-sm dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300"
          data-testid="walkthrough-annotate-accessibility-note"
        >
          {annotation.accessibilityNote}
        </span>
      ) : null}
    </div>
  )
}
