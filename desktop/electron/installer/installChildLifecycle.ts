import type { ChildProcess } from "node:child_process"

type InstallChildLifecycleDeps = {
  child: ChildProcess
  updateLock: (pid: number) => Promise<void>
  releaseLock: (force: boolean) => Promise<void>
  terminate: () => void
  onError: (error: unknown) => void
  onSettled: (code: number) => void
}

// Attach the fatal child listeners before beginning any asynchronous lock IO.
// Electron treats an unhandled ChildProcess "error" event as an uncaught
// exception, so even one await between spawn() and this registration is unsafe.
export const superviseInstallChild = ({
  child,
  updateLock,
  releaseLock,
  terminate,
  onError,
  onSettled
}: InstallChildLifecycleDeps) => {
  let settled = false
  let lockUpdateFailed = false
  let lockUpdate: Promise<void> | null = null
  let resolveCompletion: (() => void) | null = null
  const completion = new Promise<void>((resolve) => {
    resolveCompletion = resolve
  })

  const settle = (code: number) => {
    if (settled) {
      return
    }
    settled = true
    onSettled(code)
    // If spawn failed while the PID write was still pending, releasing first
    // could let that write recreate the lock after cleanup. Drain it first.
    void (lockUpdate ?? Promise.resolve())
      .then(() => releaseLock(lockUpdateFailed))
      .catch(() => {})
      .finally(() => resolveCompletion?.())
  }

  child.once("error", (error) => {
    onError(error)
    settle(1)
  })
  child.once("close", (code) => settle(code ?? 1))

  // A failed PID write must not leave an untracked installer running. Keep
  // the lock until the resulting child close/error settles the lifecycle.
  lockUpdate = updateLock(child.pid ?? process.pid).catch((error) => {
    lockUpdateFailed = true
    onError(error)
    terminate()
  })

  return completion
}
