import { useEffect, useRef, useState } from "react"
import type { CredentialTestResult } from "../api/credentials"

// Live-validation state for a pasted-but-unsaved credential. Extracted from
// GithubTokenModal's TokenStep so every credential surface can probe before
// saving instead of demanding a blind save-then-test.
export type ProbeState = { status: "idle" } | { status: "testing" } | { status: "done"; result: CredentialTestResult } | { status: "error"; message: string }

// Debounce keystrokes, then probe the trimmed value. A monotonically
// increasing sequence guards against stale results: when the value changes
// mid-flight, the superseded probe's response is dropped instead of
// overwriting the newer state.
//
// `probe` must be referentially stable (module-level fn or useCallback) —
// it sits in the effect's dependency list.
export function useDebouncedProbe(
  value: string,
  probe: (value: string) => Promise<CredentialTestResult>,
  { delayMs = 500, errorFallback = "Could not verify the value." }: { delayMs?: number; errorFallback?: string } = {}
): ProbeState {
  const [state, setState] = useState<ProbeState>({ status: "idle" })
  const probeSeq = useRef(0)

  useEffect(() => {
    const trimmed = value.trim()
    if (trimmed.length === 0) {
      // Bump the sequence so a probe still in flight for the previous value
      // cannot resolve late and overwrite idle with a green result — which
      // would re-enable Save under an empty input.
      probeSeq.current += 1
      setState({ status: "idle" })
      return
    }
    const seq = ++probeSeq.current
    setState({ status: "testing" })
    const handle = setTimeout(async () => {
      try {
        const result = await probe(trimmed)
        if (seq === probeSeq.current) setState({ status: "done", result })
      } catch (err) {
        if (seq === probeSeq.current) setState({ status: "error", message: err instanceof Error ? err.message : errorFallback })
      }
    }, delayMs)
    return () => clearTimeout(handle)
  }, [value, probe, delayMs, errorFallback])

  return state
}
