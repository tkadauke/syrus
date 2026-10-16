import type { Credentials } from "./credentialsStore.js"

type Timer = unknown

export type AppUserCableSocket = {
  readyState: number
  send: (data: string) => void
  close: () => void
  // Event shapes differ slightly between Node's WebSocket and browser-test
  // doubles; the client does not consume these transport event objects.
  onopen: ((event: any) => unknown) | null
  onmessage: ((event: any) => unknown) | null
  onerror: ((event: any) => unknown) | null
  onclose: ((event: any) => unknown) | null
}

type AppUserCableDeps = {
  createSocket: (url: string, protocol: string) => AppUserCableSocket
  cableUrl: (credentials: Credentials) => string
  credentialsKey: (credentials: Credentials) => string
  onMessage: (message: unknown) => void
  onUnauthorized: (credentials: Credentials) => void
  setTimeout?: (callback: () => void, delay: number) => Timer
  clearTimeout?: (timer: Timer) => void
}

const CHANNEL_IDENTIFIER = JSON.stringify({ channel: "AppUserChannel" })
const INITIAL_RECONNECT_MS = 1_000
const MAX_RECONNECT_MS = 30_000

export class AppUserCableClient {
  private socket: AppUserCableSocket | null = null
  private reconnectTimer: Timer | null = null
  private generation = 0
  private currentCredentialsKey: string | null = null
  private reconnectMs = INITIAL_RECONNECT_MS

  constructor(private readonly deps: AppUserCableDeps) {}

  start(credentials: Credentials | null) {
    if (!credentials) return this.stop()

    const key = this.deps.credentialsKey(credentials)
    if (this.currentCredentialsKey === key && (this.socket || this.reconnectTimer)) return

    this.generation += 1
    this.currentCredentialsKey = key
    this.reconnectMs = INITIAL_RECONNECT_MS
    this.connect(credentials, this.generation)
  }

  stop() {
    this.generation += 1
    this.currentCredentialsKey = null
    this.close()
  }

  private clearReconnect() {
    if (!this.reconnectTimer) return
    if (this.deps.clearTimeout) {
      this.deps.clearTimeout(this.reconnectTimer)
    } else {
      clearTimeout(this.reconnectTimer as ReturnType<typeof setTimeout>)
    }
    this.reconnectTimer = null
  }

  private close() {
    this.clearReconnect()
    if (!this.socket) return

    const socket = this.socket
    this.socket = null
    socket.onopen = null
    socket.onmessage = null
    socket.onerror = null
    socket.onclose = null
    if (socket.readyState === 0 || socket.readyState === 1) socket.close()
  }

  private scheduleReconnect(credentials: Credentials, generation: number) {
    if (generation !== this.generation) return

    this.clearReconnect()
    const delay = this.reconnectMs
    this.reconnectMs = Math.min(this.reconnectMs * 2, MAX_RECONNECT_MS)
    this.reconnectTimer = (this.deps.setTimeout ?? setTimeout)(() => {
      this.reconnectTimer = null
      this.connect(credentials, generation)
    }, delay)
  }

  private connect(credentials: Credentials, generation: number) {
    if (generation !== this.generation) return

    this.close()
    const socket = this.deps.createSocket(this.deps.cableUrl(credentials), "actioncable-v1-json")
    this.socket = socket

    socket.onopen = () => {
      socket.send(JSON.stringify({ command: "subscribe", identifier: CHANNEL_IDENTIFIER }))
    }

    socket.onmessage = (event) => {
      if (generation !== this.generation) return

      let message: { type?: string; reason?: string; message?: unknown }
      try {
        message = JSON.parse(String(event.data)) as typeof message
      } catch {
        return
      }
      if (!message || typeof message !== "object") return

      if (message.type === "disconnect" && message.reason === "unauthorized") {
        this.deps.onUnauthorized(credentials)
        this.stop()
        return
      }
      if (message.type === "reject_subscription") {
        socket.close()
        return
      }
      // The upgrade alone does not prove that the token or channel is usable.
      if (message.type === "confirm_subscription") {
        this.reconnectMs = INITIAL_RECONNECT_MS
        return
      }
      if ("message" in message) this.deps.onMessage(message.message)
    }

    let finished = false
    const finish = () => {
      if (finished) return
      finished = true
      if (this.socket === socket) this.socket = null
      this.scheduleReconnect(credentials, generation)
    }
    socket.onerror = finish
    socket.onclose = finish
  }
}
