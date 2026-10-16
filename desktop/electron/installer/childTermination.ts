import { execFile, type ChildProcess } from "node:child_process"

type Timer = ReturnType<typeof setTimeout>

type TerminationDeps = {
  platform: NodeJS.Platform
  killGroup: (pid: number, signal: NodeJS.Signals) => void
  killTree: (pid: number) => void
  setTimer: (callback: () => void, delay: number) => Timer
  clearTimer: (timer: Timer) => void
}

const defaultDeps: TerminationDeps = {
  platform: process.platform,
  killGroup: (pid, signal) => process.kill(-pid, signal),
  killTree: (pid) => execFile("taskkill", ["/pid", String(pid), "/T", "/F"], { windowsHide: true }, () => {}),
  setTimer: (callback, delay) => setTimeout(callback, delay),
  clearTimer: (timer) => clearTimeout(timer)
}

// Owns one detached installer until it closes or a forceful termination has
// actually been sent. Settling the caller's promise is deliberately separate:
// a timed-out installer still owns the stack during its TERM grace period.
export class ChildTerminationController {
  private child: ChildProcess | null = null
  private killTimer: Timer | null = null

  constructor(
    private readonly graceMs: number,
    private readonly deps: TerminationDeps = defaultDeps
  ) {}

  register(child: ChildProcess) {
    if (this.child) throw new Error("an installer child is already registered")
    this.child = child
  }

  active() {
    return this.child !== null
  }

  clear(child: ChildProcess) {
    if (this.child !== child) return
    if (this.killTimer) this.deps.clearTimer(this.killTimer)
    this.killTimer = null
    this.child = null
  }

  terminate(force = false) {
    const child = this.child
    if (!child?.pid) return

    if (this.deps.platform === "win32") {
      this.deps.killTree(child.pid)
      this.clear(child)
      return
    }

    if (force) {
      if (this.killTimer) this.deps.clearTimer(this.killTimer)
      this.killTimer = null
      this.signal(child, "SIGKILL")
      this.child = null
      return
    }

    this.signal(child, "SIGTERM")
    if (!this.killTimer) {
      this.killTimer = this.deps.setTimer(() => {
        this.killTimer = null
        if (this.child !== child) return
        this.signal(child, "SIGKILL")
        this.child = null
      }, this.graceMs)
    }
  }

  private signal(child: ChildProcess, signal: NodeJS.Signals) {
    try {
      this.deps.killGroup(child.pid!, signal)
    } catch {
      child.kill(signal)
    }
  }
}
