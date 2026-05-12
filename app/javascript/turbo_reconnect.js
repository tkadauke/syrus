const RECONNECT_CHECK_DELAY_MS = 250

let reconnectTimer = null

export function reconnectStaleCableStreamSources() {
  if (document.hidden) return

  document.querySelectorAll("turbo-cable-stream-source").forEach((source) => {
    if (source.hasAttribute("connected")) return
    if (!source.subscription) return
    if (typeof source.disconnectedCallback !== "function") return
    if (typeof source.connectedCallback !== "function") return

    source.disconnectedCallback()
    source.connectedCallback()
  })
}

export function scheduleCableStreamReconnectCheck() {
  if (reconnectTimer) clearTimeout(reconnectTimer)

  reconnectTimer = setTimeout(() => {
    reconnectTimer = null
    reconnectStaleCableStreamSources()
  }, RECONNECT_CHECK_DELAY_MS)
}

document.addEventListener("visibilitychange", () => {
  if (!document.hidden) scheduleCableStreamReconnectCheck()
})

window.addEventListener("focus", scheduleCableStreamReconnectCheck)
window.addEventListener("pageshow", (event) => {
  if (event.persisted) scheduleCableStreamReconnectCheck()
})
