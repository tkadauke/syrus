import { act, fireEvent, render, renderHook, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  ANALYZING_HINT_INTERVAL_MS,
  AnalyzingHint,
  annotationHoldLabel,
  annotationIdleHintKind,
  annotationShortcutLabel,
  formatClock,
  isMacPlatform,
  pickRecorderMimeType,
  RECORDER_MIME_CANDIDATES,
  RECORDER_WARNING_SECONDS,
  shouldShowAnnotationSurfaceNote,
  useNativeRecorderHud,
  useWalkthroughRecorder,
  WalkthroughRecorderHUD
} from "./WalkthroughRecorder"
import { MAX_WALKTHROUGH_DURATION_SECONDS } from "../api/videoWalkthroughs"
import type { SyrusAnnotationBridge, SyrusRecorderHudBridge } from "../lib/desktopShell"

describe("formatClock", () => {
  it("renders zero as 0:00", () => {
    expect(formatClock(0)).toBe("0:00")
  })

  it("renders 61 seconds as 1:01", () => {
    expect(formatClock(61)).toBe("1:01")
  })

  it("renders the 900-second cap as 15:00", () => {
    expect(formatClock(900)).toBe("15:00")
  })

  it("clamps negative values to 0:00", () => {
    expect(formatClock(-1)).toBe("0:00")
    expect(formatClock(-900)).toBe("0:00")
  })
})

describe("pickRecorderMimeType", () => {
  it("prefers vp9 when everything is supported", () => {
    expect(pickRecorderMimeType(() => true)).toBe("video/webm;codecs=vp9,opus")
  })

  it("falls back to vp8 when vp9 is unsupported", () => {
    expect(pickRecorderMimeType((type) => !type.includes("vp9"))).toBe("video/webm;codecs=vp8,opus")
  })

  it("falls back to plain webm when no codec-specific type is supported", () => {
    expect(pickRecorderMimeType((type) => !type.includes("codecs"))).toBe("video/webm")
  })

  it("falls back to mp4 when only mp4 is supported", () => {
    expect(pickRecorderMimeType((type) => type === "video/mp4")).toBe("video/mp4")
  })

  it("returns null when nothing is supported", () => {
    expect(pickRecorderMimeType(() => false)).toBeNull()
  })

  it("probes the candidates in preference order", () => {
    expect(RECORDER_MIME_CANDIDATES).toEqual(["video/webm;codecs=vp9,opus", "video/webm;codecs=vp8,opus", "video/webm", "video/mp4"])
  })
})

// The recorder derives durationSeconds from its OWN clock (Date.now at start
// vs stop), never by re-measuring the produced blob — a MediaRecorder webm's
// metadata duration is Infinity, so the wall-clock is the only reliable
// source for the ≥12-min gate. This exercises that onFinished contract.
class FakeMediaRecorder {
  static isTypeSupported = () => true
  ondataavailable: ((event: { data: Blob }) => void) | null = null
  onstop: (() => void) | null = null
  mimeType = "video/webm"
  start = vi.fn()
  stop = vi.fn(() => {
    this.ondataavailable?.({ data: new Blob(["chunk"], { type: "video/webm" }) })
    this.onstop?.()
  })
}

function fakeTrack() {
  return { stop: vi.fn(), addEventListener: vi.fn() }
}

function fakeStream() {
  const track = fakeTrack()
  return { getTracks: () => [track], getVideoTracks: () => [track], getAudioTracks: () => [track] } as unknown as MediaStream
}

describe("useWalkthroughRecorder onFinished", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    vi.useRealTimers()
  })

  it("delivers a numeric durationSeconds derived from the wall clock, not the blob", async () => {
    const onFinished = vi.fn()
    let recorder: FakeMediaRecorder | null = null

    vi.stubGlobal(
      "MediaRecorder",
      class extends FakeMediaRecorder {
        constructor() {
          super()
          recorder = this
        }
      }
    )
    vi.stubGlobal(
      "MediaStream",
      class {
        // The hook wraps the picked tracks in a fresh MediaStream — jsdom has none.
      }
    )
    vi.stubGlobal("navigator", {
      ...navigator,
      mediaDevices: {
        getDisplayMedia: vi.fn().mockResolvedValue(fakeStream()),
        getUserMedia: vi.fn().mockResolvedValue(fakeStream())
      }
    })
    const nowSpy = vi.spyOn(Date, "now")
    nowSpy.mockReturnValue(1_000_000) // start clock

    const { result } = renderHook(() => useWalkthroughRecorder({ onFinished }))

    await act(async () => {
      await result.current.start()
    })
    expect(recorder).not.toBeNull()

    // 7.4s elapsed on the recorder's clock → rounds to 7.
    nowSpy.mockReturnValue(1_007_400)
    act(() => {
      result.current.stop()
    })

    await waitFor(() => expect(onFinished).toHaveBeenCalledTimes(1))
    const result0 = onFinished.mock.calls[0][0]
    expect(typeof result0.durationSeconds).toBe("number")
    expect(result0.durationSeconds).toBe(7)
    expect(result0.blob).toBeInstanceOf(Blob)
    expect(result0.mimeType).toBe("video/webm")

    vi.unstubAllGlobals()
  })
})

describe("annotation helpers", () => {
  it("detects macOS from the user agent", () => {
    expect(isMacPlatform("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)")).toBe(true)
    expect(isMacPlatform("Mozilla/5.0 (Windows NT 10.0; Win64; x64)")).toBe(false)
    expect(isMacPlatform("Mozilla/5.0 (X11; Linux x86_64)")).toBe(false)
  })

  it("formats the draw-mode accelerator per platform", () => {
    expect(annotationShortcutLabel(true)).toBe("⌘⇧A")
    expect(annotationShortcutLabel(false)).toBe("Ctrl+Shift+A")
  })

  it("keeps the hold-modifier label tiny (bare glyph on macOS)", () => {
    expect(annotationHoldLabel(true)).toBe("⌃")
    expect(annotationHoldLabel(false)).toBe("Ctrl")
  })

  it("picks the idle hint kind from the live mode + failure reason", () => {
    // Hold is live → the hold hint, whatever reason may linger.
    expect(annotationIdleHintKind(true)).toBe("hold")
    expect(annotationIdleHintKind(true, "no-accessibility")).toBe("hold")
    // Hold failed only for the macOS permission → the grant-Accessibility
    // nudge (tap keeps working, and granting upgrades the next recording).
    expect(annotationIdleHintKind(false, "no-accessibility")).toBe("accessibility")
    // Any other degrade (module missing, start failure, old shell without
    // reason reporting) → the plain tap hint.
    expect(annotationIdleHintKind(false, "no-module")).toBe("tap")
    expect(annotationIdleHintKind(false, "start-failed")).toBe("tap")
    expect(annotationIdleHintKind(false, null)).toBe("tap")
    expect(annotationIdleHintKind(false)).toBe("tap")
  })

  it("shows the whole-screen note only for window/browser captures when annotation is available", () => {
    expect(shouldShowAnnotationSurfaceNote(true, "monitor")).toBe(false)
    expect(shouldShowAnnotationSurfaceNote(true, "window")).toBe(true)
    expect(shouldShowAnnotationSurfaceNote(true, "browser")).toBe(true)
    // Unknown surface (older engines) → assume it's fine, no note.
    expect(shouldShowAnnotationSurfaceNote(true, null)).toBe(false)
    // No annotation surface → never a note.
    expect(shouldShowAnnotationSurfaceNote(false, "window")).toBe(false)
  })
})

// The recorder arms/tears down the desktop red-pen overlay across the
// recording lifecycle. These stub the media stack (as above) and inject a fake
// annotation bridge to pin the enable-on-start / disable-on-stop contract and
// the draw-mode + capture-surface plumbing.
describe("useWalkthroughRecorder annotation", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
    vi.useRealTimers()
  })

  function fakeAnnotation(overrides: Partial<SyrusAnnotationBridge> = {}) {
    let modeCallback: ((drawing: boolean) => void) | null = null
    const unsubscribe = vi.fn()
    const bridge: SyrusAnnotationBridge = {
      available: true,
      // enable() resolves { available, hold } when a surface came up — that
      // runtime signal (not mere bridge presence) drives the HUD hint, and
      // `hold` picks the "hold Ctrl" vs "tap ⌘⇧A" wording.
      enable: vi.fn().mockResolvedValue({ available: true, hold: false }),
      disable: vi.fn().mockResolvedValue(undefined),
      onModeChanged: vi.fn((cb: (drawing: boolean) => void) => {
        modeCallback = cb
        return unsubscribe
      }),
      ...overrides
    }
    return { bridge, unsubscribe, emitMode: (drawing: boolean) => modeCallback?.(drawing) }
  }

  function stubMedia(displaySurface: string | null = "monitor") {
    const track = {
      stop: vi.fn(),
      addEventListener: vi.fn(),
      getSettings: () => (displaySurface === null ? {} : { displaySurface })
    }
    const stream = {
      getTracks: () => [track],
      getVideoTracks: () => [track],
      getAudioTracks: () => [track]
    } as unknown as MediaStream

    vi.stubGlobal("MediaRecorder", class extends FakeMediaRecorder {})
    vi.stubGlobal("MediaStream", class {})
    vi.stubGlobal("navigator", {
      ...navigator,
      mediaDevices: {
        getDisplayMedia: vi.fn().mockResolvedValue(stream),
        getUserMedia: vi.fn().mockResolvedValue(stream)
      }
    })
  }

  it("enables the overlay on start and disables it on stop", async () => {
    stubMedia()
    const { bridge } = fakeAnnotation()
    const { result } = renderHook(() => useWalkthroughRecorder({ onFinished: vi.fn(), annotation: bridge }))

    // Runtime gate: nothing is advertised until enable() resolves true.
    expect(result.current.annotationAvailable).toBe(false)

    await act(async () => {
      await result.current.start()
    })
    expect(bridge.enable).toHaveBeenCalledTimes(1)
    // enable() resolved true, so the HUD hint is now allowed.
    expect(result.current.annotationAvailable).toBe(true)

    act(() => {
      result.current.stop({ discard: true })
    })
    expect(bridge.disable).toHaveBeenCalled()
    // Torn down on stop, so the gate closes again.
    expect(result.current.annotationAvailable).toBe(false)
  })

  it("withholds the HUD hint when enable() reports the overlay unavailable", async () => {
    stubMedia()
    // A stolen accelerator or a compositor that can't host the overlay makes
    // the main process report false — the recorder must NOT advertise ⌘⇧A.
    const { bridge } = fakeAnnotation({ enable: vi.fn().mockResolvedValue({ available: false, hold: false }) })
    const { result } = renderHook(() => useWalkthroughRecorder({ onFinished: vi.fn(), annotation: bridge }))

    await act(async () => {
      await result.current.start()
    })
    expect(bridge.enable).toHaveBeenCalledTimes(1)
    // enable() resolved unavailable → no HUD affordance, recording still proceeds.
    expect(result.current.annotationAvailable).toBe(false)
    expect(result.current.state.phase).toBe("recording")

    act(() => {
      result.current.stop({ discard: true })
    })
    expect(bridge.disable).toHaveBeenCalled()
  })

  it("ignores a late enable() resolution that lands after the recording stopped", async () => {
    stubMedia()
    // enable() resolves only when we release it — after stop() — so the guard
    // must drop the stale true and keep the HUD gate closed.
    let releaseEnable: (result: { available: boolean; hold: boolean }) => void = () => {}
    const enable = vi.fn(
      () =>
        new Promise<{ available: boolean; hold: boolean }>((resolve) => {
          releaseEnable = resolve
        })
    )
    const { bridge } = fakeAnnotation({ enable })
    const { result } = renderHook(() => useWalkthroughRecorder({ onFinished: vi.fn(), annotation: bridge }))

    await act(async () => {
      await result.current.start()
    })
    act(() => {
      result.current.stop({ discard: true })
    })
    await act(async () => {
      releaseEnable({ available: true, hold: false })
      await Promise.resolve()
    })
    expect(result.current.annotationAvailable).toBe(false)
  })

  it("reports hold mode from enable() so the HUD can show the right hint", async () => {
    stubMedia()
    const { bridge } = fakeAnnotation({ enable: vi.fn().mockResolvedValue({ available: true, hold: true }) })
    const { result } = renderHook(() => useWalkthroughRecorder({ onFinished: vi.fn(), annotation: bridge }))

    await act(async () => {
      await result.current.start()
    })
    expect(result.current.annotationAvailable).toBe(true)
    expect(result.current.annotationHold).toBe(true)
    // Hold came up — no failure reason to surface.
    expect(result.current.annotationReason).toBeNull()

    act(() => {
      result.current.stop({ discard: true })
    })
    expect(result.current.annotationHold).toBe(false)
  })

  it("threads the hold-failure reason through so the HUD can nudge for Accessibility", async () => {
    stubMedia()
    // macOS without the Accessibility permission: the overlay comes up in TAP
    // mode and reports WHY hold couldn't start. The recorder exposes that so
    // the HUD idle hint can tell the user granting the permission fixes it.
    const { bridge } = fakeAnnotation({
      enable: vi.fn().mockResolvedValue({ available: true, hold: false, reason: "no-accessibility" })
    })
    const { result } = renderHook(() => useWalkthroughRecorder({ onFinished: vi.fn(), annotation: bridge }))

    await act(async () => {
      await result.current.start()
    })
    expect(result.current.annotationAvailable).toBe(true)
    expect(result.current.annotationHold).toBe(false)
    expect(result.current.annotationReason).toBe("no-accessibility")

    // Torn down with the rest of the annotation state on stop.
    act(() => {
      result.current.stop({ discard: true })
    })
    expect(result.current.annotationReason).toBeNull()
  })

  it("leaves the reason null when an older shell reports no reason", async () => {
    stubMedia()
    const { bridge } = fakeAnnotation({
      enable: vi.fn().mockResolvedValue({ available: true, hold: false })
    })
    const { result } = renderHook(() => useWalkthroughRecorder({ onFinished: vi.fn(), annotation: bridge }))

    await act(async () => {
      await result.current.start()
    })
    expect(result.current.annotationAvailable).toBe(true)
    expect(result.current.annotationReason).toBeNull()
  })

  it("reflects arm + auto-release transitions pushed from the overlay", async () => {
    stubMedia()
    const { bridge, emitMode } = fakeAnnotation()
    const { result } = renderHook(() => useWalkthroughRecorder({ onFinished: vi.fn(), annotation: bridge }))

    await act(async () => {
      await result.current.start()
    })
    // Click-through by default — nothing armed until the user taps the shortcut.
    expect(result.current.drawing).toBe(false)

    // Tap arms (overlay pushes true)...
    act(() => emitMode(true))
    expect(result.current.drawing).toBe(true)

    // ...and the overlay AUTO-RELEASES when the user pauses (pushes false),
    // flipping the HUD back to the idle hint with no toggle-off from the user.
    act(() => emitMode(false))
    expect(result.current.drawing).toBe(false)

    // A fresh tap re-arms — the shortcut stays a press-to-arm, not a one-shot.
    act(() => emitMode(true))
    expect(result.current.drawing).toBe(true)
  })

  it("captures the shared display surface for the whole-screen nudge", async () => {
    stubMedia("window")
    const { bridge } = fakeAnnotation()
    const { result } = renderHook(() => useWalkthroughRecorder({ onFinished: vi.fn(), annotation: bridge }))

    await act(async () => {
      await result.current.start()
    })
    expect(result.current.displaySurface).toBe("window")
  })

  it("reports annotation unavailable and never calls the bridge when there is none", async () => {
    stubMedia()
    const { result } = renderHook(() => useWalkthroughRecorder({ onFinished: vi.fn(), annotation: null }))

    expect(result.current.annotationAvailable).toBe(false)

    await act(async () => {
      await result.current.start()
    })
    // No throw, recording proceeds; nothing to assert beyond a clean start.
    act(() => {
      result.current.stop({ discard: true })
    })
    expect(result.current.annotationAvailable).toBe(false)
  })
})

const hudLabels = {
  recording: "Recording",
  noMic: "No microphone",
  stop: "Stop",
  discard: "Discard",
  remaining: (clock: string) => `${clock} left`
}

function renderHud(props: { elapsed?: number; micLive?: boolean; onStop?: () => void; onDiscard?: () => void } = {}) {
  return render(
    <WalkthroughRecorderHUD
      elapsed={props.elapsed ?? 0}
      labels={hudLabels}
      micLive={props.micLive ?? true}
      onDiscard={props.onDiscard ?? (() => {})}
      onStop={props.onStop ?? (() => {})}
    />
  )
}

describe("WalkthroughRecorderHUD", () => {
  it("shows the elapsed clock and remaining countdown", () => {
    renderHud({ elapsed: 61 })

    expect(screen.getByTestId("walkthrough-recorder-hud")).toHaveTextContent("Recording 1:01")
    // 900 - 61 = 839 seconds = 13:59 remaining.
    expect(screen.getByTestId("walkthrough-recorder-remaining")).toHaveTextContent("13:59 left")
  })

  it("keeps the countdown neutral before the final-minute warning", () => {
    renderHud({ elapsed: RECORDER_WARNING_SECONDS - 1 })

    expect(screen.getByTestId("walkthrough-recorder-remaining").className).not.toContain("text-amber-600")
  })

  it("turns the countdown amber at the warning threshold", () => {
    renderHud({ elapsed: RECORDER_WARNING_SECONDS })

    const remaining = screen.getByTestId("walkthrough-recorder-remaining")
    expect(remaining).toHaveTextContent(`${formatClock(MAX_WALKTHROUGH_DURATION_SECONDS - RECORDER_WARNING_SECONDS)} left`)
    expect(remaining.className).toContain("text-amber-600")
  })

  it("stays amber past the threshold", () => {
    renderHud({ elapsed: RECORDER_WARNING_SECONDS + 30 })

    expect(screen.getByTestId("walkthrough-recorder-remaining").className).toContain("text-amber-600")
  })

  it("fires the stop callback", () => {
    const onStop = vi.fn()
    renderHud({ onStop })

    fireEvent.click(screen.getByRole("button", { name: "Stop" }))
    expect(onStop).toHaveBeenCalledTimes(1)
  })

  it("fires the discard callback", () => {
    const onDiscard = vi.fn()
    renderHud({ onDiscard })

    fireEvent.click(screen.getByRole("button", { name: "Discard" }))
    expect(onDiscard).toHaveBeenCalledTimes(1)
  })

  it("shows the no-mic label only when the mic is not live", () => {
    const { unmount } = renderHud({ micLive: false })
    expect(screen.getByText("No microphone")).toBeInTheDocument()
    unmount()

    renderHud({ micLive: true })
    expect(screen.queryByText("No microphone")).not.toBeInTheDocument()
  })

  it("renders the window-capture hint only when a label is supplied", () => {
    render(<WalkthroughRecorderHUD elapsed={0} labels={{ ...hudLabels, windowHint: "keep the window small" }} micLive onDiscard={() => {}} onStop={() => {}} />)
    expect(screen.getByTestId("walkthrough-recorder-window-hint")).toHaveTextContent("keep the window small")
  })

  it("omits the window-capture hint when no label is supplied", () => {
    renderHud()
    expect(screen.queryByTestId("walkthrough-recorder-window-hint")).not.toBeInTheDocument()
  })

  it("shows no annotation affordance when the annotation prop is absent", () => {
    renderHud()
    expect(screen.queryByTestId("walkthrough-annotate-hint")).not.toBeInTheDocument()
    expect(screen.queryByTestId("walkthrough-annotate-surface-note")).not.toBeInTheDocument()
  })

  it("shows a QUIET idle hint — muted text beside a tiny gray dot, never red", () => {
    render(
      <WalkthroughRecorderHUD
        annotation={{ hint: "⌘⇧A to draw", drawingHint: "Drawing · Esc", drawing: false }}
        elapsed={0}
        labels={hudLabels}
        micLive
        onDiscard={() => {}}
        onStop={() => {}}
      />
    )
    const hint = screen.getByTestId("walkthrough-annotate-hint")
    expect(hint).toHaveTextContent("⌘⇧A to draw")
    // The redesigned hint stays neutral in BOTH states — no red text, no bold.
    expect(hint.className).not.toContain("text-red-600")
    expect(hint.className).not.toContain("font-semibold")
    expect(hint.className).toContain("text-gray-500")
    // Idle keeps the small-screen gate; the status dot is gray while idle.
    expect(hint.className).toContain("hidden sm:inline-flex")
    expect(screen.getByTestId("walkthrough-annotate-dot").className).toContain("bg-gray-400")
  })

  it("flips only the dot to red (and stays visible) while the pen is armed", () => {
    render(
      <WalkthroughRecorderHUD
        annotation={{ hint: "⌘⇧A to draw", drawingHint: "Drawing · Esc", drawing: true }}
        elapsed={0}
        labels={hudLabels}
        micLive
        onDiscard={() => {}}
        onStop={() => {}}
      />
    )
    const hint = screen.getByTestId("walkthrough-annotate-hint")
    expect(hint).toHaveTextContent("Drawing · Esc")
    // Subtle by design: the DRAWING state is a small red dot, not shouting
    // red bold text (the old design overwhelmed the HUD).
    expect(hint.className).not.toContain("text-red-600")
    expect(hint.className).not.toContain("font-semibold")
    expect(screen.getByTestId("walkthrough-annotate-dot").className).toContain("bg-red-600")
    // While drawing the status is always visible, not gated behind sm:.
    expect(hint.className).toContain("inline-flex")
    expect(hint.className).not.toContain("hidden")
  })

  it("shows the System Settings guidance only when an accessibility note is supplied", () => {
    const annotation = { hint: "⌘⇧A to draw", drawingHint: "Drawing · Esc", drawing: false }
    const { unmount } = render(
      <WalkthroughRecorderHUD
        annotation={{ ...annotation, accessibilityNote: "Allow Syrus under System Settings → Privacy & Security → Accessibility" }}
        elapsed={0}
        labels={hudLabels}
        micLive
        onDiscard={() => {}}
        onStop={() => {}}
      />
    )
    expect(screen.getByTestId("walkthrough-annotate-accessibility-note")).toHaveTextContent("System Settings → Privacy & Security → Accessibility")
    unmount()

    render(<WalkthroughRecorderHUD annotation={annotation} elapsed={0} labels={hudLabels} micLive onDiscard={() => {}} onStop={() => {}} />)
    expect(screen.queryByTestId("walkthrough-annotate-accessibility-note")).not.toBeInTheDocument()
  })

  it("shows the capture-surface note only when one is supplied", () => {
    const { unmount } = render(
      <WalkthroughRecorderHUD
        annotation={{
          hint: "Draw on screen — tap ⌘⇧A",
          drawingHint: "Drawing — auto-exits when you pause · Esc",
          drawing: false,
          surfaceNote: "Share your whole screen to see marks"
        }}
        elapsed={0}
        labels={hudLabels}
        micLive
        onDiscard={() => {}}
        onStop={() => {}}
      />
    )
    expect(screen.getByTestId("walkthrough-annotate-surface-note")).toHaveTextContent("Share your whole screen to see marks")
    unmount()

    render(
      <WalkthroughRecorderHUD
        annotation={{ hint: "Draw on screen — tap ⌘⇧A", drawingHint: "Drawing — auto-exits when you pause · Esc", drawing: false }}
        elapsed={0}
        labels={hudLabels}
        micLive
        onDiscard={() => {}}
        onStop={() => {}}
      />
    )
    expect(screen.queryByTestId("walkthrough-annotate-surface-note")).not.toBeInTheDocument()
  })
})

describe("AnalyzingHint", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("renders the first message and cycles to the next on the interval", () => {
    vi.useFakeTimers()
    const messages = ["Watching your walkthrough…", "Reading the screen…", "Almost done…"]
    render(<AnalyzingHint intervalMs={4000} messages={messages} />)

    const hint = screen.getByTestId("walkthrough-analyzing-hint")
    expect(hint).toHaveTextContent(messages[0])

    act(() => {
      vi.advanceTimersByTime(4000)
    })
    expect(hint).toHaveTextContent(messages[1])

    act(() => {
      vi.advanceTimersByTime(4000)
    })
    expect(hint).toHaveTextContent(messages[2])
  })

  it("wraps back to the first message after the last", () => {
    vi.useFakeTimers()
    const messages = ["one", "two"]
    render(<AnalyzingHint intervalMs={1000} messages={messages} />)

    const hint = screen.getByTestId("walkthrough-analyzing-hint")
    expect(hint).toHaveTextContent("one")
    act(() => {
      vi.advanceTimersByTime(1000)
    })
    expect(hint).toHaveTextContent("two")
    act(() => {
      vi.advanceTimersByTime(1000)
    })
    expect(hint).toHaveTextContent("one")
  })

  it("holds a single message without scheduling a timer", () => {
    vi.useFakeTimers()
    render(<AnalyzingHint messages={["only one"]} />)

    const hint = screen.getByTestId("walkthrough-analyzing-hint")
    expect(hint).toHaveTextContent("only one")
    act(() => {
      vi.advanceTimersByTime(ANALYZING_HINT_INTERVAL_MS * 3)
    })
    expect(hint).toHaveTextContent("only one")
  })
})

describe("useNativeRecorderHud", () => {
  function fakeBridge() {
    const calls = { show: [] as unknown[], update: [] as unknown[], hide: 0 }
    let actionCb: ((kind: "stop" | "discard") => void) | null = null
    const bridge: SyrusRecorderHudBridge = {
      available: true,
      show: (state) => {
        calls.show.push(state)
        return Promise.resolve()
      },
      update: (state) => {
        calls.update.push(state)
        return Promise.resolve()
      },
      hide: () => {
        calls.hide += 1
        return Promise.resolve()
      },
      onAction: (callback) => {
        actionCb = callback
        return () => {
          actionCb = null
        }
      }
    }
    return { bridge, calls, fire: (kind: "stop" | "discard") => actionCb?.(kind) }
  }

  it("shows on record start, updates on state change, and hides on stop", () => {
    const seam = fakeBridge()
    const { rerender } = renderHook(
      ({ recording, clock }: { recording: boolean; clock: string }) =>
        useNativeRecorderHud({ recording, state: { clock }, onStop: () => {}, onDiscard: () => {}, bridge: seam.bridge }),
      { initialProps: { recording: true, clock: "0:01" } }
    )

    expect(seam.calls.show).toHaveLength(1)
    expect(seam.calls.hide).toBe(0)

    rerender({ recording: true, clock: "0:02" })
    expect(seam.calls.update.length).toBeGreaterThanOrEqual(1)
    expect(seam.calls.show).toHaveLength(1) // shown once, not re-shown

    rerender({ recording: false, clock: "0:02" })
    expect(seam.calls.hide).toBe(1)
  })

  it("routes the HUD's Stop and Discard clicks to the callbacks", () => {
    const seam = fakeBridge()
    const onStop = vi.fn()
    const onDiscard = vi.fn()
    renderHook(() => useNativeRecorderHud({ recording: true, state: {}, onStop, onDiscard, bridge: seam.bridge }))

    act(() => {
      seam.fire("stop")
    })
    expect(onStop).toHaveBeenCalledTimes(1)
    act(() => {
      seam.fire("discard")
    })
    expect(onDiscard).toHaveBeenCalledTimes(1)
  })

  it("is inactive (returns false) with no bridge — a plain browser keeps the in-page HUD", () => {
    const { result } = renderHook(() => useNativeRecorderHud({ recording: true, state: {}, onStop: () => {}, onDiscard: () => {}, bridge: null }))
    expect(result.current).toBe(false)
  })
})
