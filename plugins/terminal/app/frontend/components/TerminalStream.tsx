import "xterm/css/xterm.css"

import { createConsumer, type Subscription } from "@rails/actioncable"
import { FitAddon } from "@xterm/addon-fit"
import { Terminal } from "xterm"
import { useEffect, useLayoutEffect, useRef, useState } from "react"

export type TerminalConnectionState = {
  connected: boolean
  ended: boolean
}

type TerminalStreamProps = {
  terminalSessionId: number
  inputEnabled?: boolean
  className?: string
  containerClassName?: string
  endedOverlayText?: string
  onConnectionChange?: (state: TerminalConnectionState) => void
}

export function TerminalStream({
  terminalSessionId,
  inputEnabled = true,
  className = "relative flex min-h-0 flex-1 flex-col",
  containerClassName = "min-h-0 flex-1 overflow-hidden bg-gray-900 p-2",
  endedOverlayText = "Session ended - reload to reconnect",
  onConnectionChange
}: TerminalStreamProps) {
  const containerRef = useRef<HTMLDivElement | null>(null)
  const inputEnabledRef = useRef(inputEnabled)
  const [ connected, setConnected ] = useState(true)
  const [ ended, setEnded ] = useState(false)
  const [ paneReady, setPaneReady ] = useState(false)

  useEffect(() => {
    inputEnabledRef.current = inputEnabled
  }, [ inputEnabled ])

  useEffect(() => {
    setConnected(true)
    setEnded(false)
  }, [ terminalSessionId ])

  useEffect(() => {
    onConnectionChange?.({ connected, ended })
  }, [ connected, ended, onConnectionChange ])

  useLayoutEffect(() => {
    if (!containerRef.current) return

    const element = containerRef.current
    let measureFrame: number | null = null
    const markReady = (width: number, height: number) => {
      if (width > 0 && height > 0) setPaneReady(true)
    }
    const measure = () => {
      const rect = element.getBoundingClientRect()
      markReady(rect.width, rect.height)
    }

    measureFrame = window.requestAnimationFrame(measure)
    window.addEventListener("resize", measure)
    const resizeObserver =
      typeof ResizeObserver === "undefined"
        ? null
        : new ResizeObserver((entries) => {
            for (const entry of entries) markReady(entry.contentRect.width, entry.contentRect.height)
          })
    resizeObserver?.observe(element)

    return () => {
      if (measureFrame !== null) window.cancelAnimationFrame(measureFrame)
      window.removeEventListener("resize", measure)
      resizeObserver?.disconnect()
    }
  }, [])

  useEffect(() => {
    if (!containerRef.current || !paneReady) return

    const terminal = new Terminal({
      convertEol: true,
      theme: {
        background: "#111827",
        foreground: "#e5e7eb",
        cursor: "#e8c3b3",
        selectionBackground: "#374151"
      }
    })
    const fitAddon = new FitAddon()
    terminal.loadAddon(fitAddon)
    terminal.open(containerRef.current)

    const doFit = () => {
      fitAddon.fit()
    }

    doFit()

    const subscription: Subscription = createConsumer().subscriptions.create(
      { channel: "TerminalChannel", session_id: terminalSessionId },
      {
        connected() {
          subscription.perform("receive", { type: "resize", cols: terminal.cols, rows: terminal.rows })
        },
        received(data: { type?: string; data?: string }) {
          if (data.type === "output" && data.data) {
            terminal.write(Uint8Array.from(atob(data.data), (character) => character.charCodeAt(0)))
          } else if (data.type === "replay" && data.data) {
            terminal.write(Uint8Array.from(atob(data.data), (character) => character.charCodeAt(0)))
          } else if (data.type === "disconnected") {
            setConnected(false)
            setEnded(true)
          }
        }
      }
    )

    const inputDisposable = terminal.onData((data) => {
      if (inputEnabledRef.current) subscription.perform("receive", { type: "input", data })
    })
    const resizeDisposable = terminal.onResize(({ cols, rows }) => {
      subscription.perform("receive", { type: "resize", cols, rows })
    })
    const resizeObserver =
      typeof ResizeObserver === "undefined"
        ? null
        : new ResizeObserver((entries) => {
            for (const entry of entries) {
              if (entry.contentRect.width > 0 && entry.contentRect.height > 0) doFit()
            }
          })
    resizeObserver?.observe(containerRef.current)

    return () => {
      resizeObserver?.disconnect()
      inputDisposable.dispose()
      resizeDisposable.dispose()
      subscription.unsubscribe()
      terminal.dispose()
    }
  }, [ paneReady, terminalSessionId ])

  return (
    <div className={className}>
      <div className={containerClassName} ref={containerRef} />
      {ended ? (
        <div className="absolute inset-0 flex items-center justify-center bg-gray-950/60 text-sm text-gray-300">
          {endedOverlayText}
        </div>
      ) : null}
    </div>
  )
}
