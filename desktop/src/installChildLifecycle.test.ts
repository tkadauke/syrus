import { EventEmitter } from "node:events"
import type { ChildProcess } from "node:child_process"
import { describe, expect, it, vi } from "vitest"
import { superviseInstallChild } from "../electron/installer/installChildLifecycle"

const deferred = () => {
  let resolve!: () => void
  let reject!: (error: Error) => void
  const promise = new Promise<void>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise
    reject = rejectPromise
  })
  return { promise, resolve, reject }
}

const fakeChild = () => {
  const child = new EventEmitter() as ChildProcess
  Object.defineProperty(child, "pid", { value: 4321 })
  return child
}

describe("superviseInstallChild", () => {
  it("handles a spawn error emitted while the PID lock write is pending", async () => {
    const child = fakeChild()
    const lockWrite = deferred()
    const releaseLock = vi.fn(async (_force: boolean) => {})
    const onError = vi.fn()
    const onSettled = vi.fn()

    const completion = superviseInstallChild({
      child,
      updateLock: () => lockWrite.promise,
      releaseLock,
      terminate: vi.fn(),
      onError,
      onSettled
    })
    const spawnError = new Error("ENOENT")
    child.emit("error", spawnError)

    expect(onError).toHaveBeenCalledWith(spawnError)
    expect(onSettled).toHaveBeenCalledWith(1)
    expect(releaseLock).not.toHaveBeenCalled()
    lockWrite.resolve()
    await completion
    expect(releaseLock).toHaveBeenCalledWith(false)
  })

  it("terminates on a lock-write failure and completes only after close and cleanup", async () => {
    const child = fakeChild()
    const release = deferred()
    const releaseLock = vi.fn((_force: boolean) => release.promise)
    const terminate = vi.fn()
    const lockError = new Error("lock write failed")
    const onError = vi.fn()
    let completed = false

    const completion = superviseInstallChild({
      child,
      updateLock: async () => {
        throw lockError
      },
      releaseLock,
      terminate,
      onError,
      onSettled: vi.fn()
    }).then(() => {
      completed = true
    })

    await vi.waitFor(() => expect(terminate).toHaveBeenCalledOnce())
    expect(onError).toHaveBeenCalledWith(lockError)
    expect(releaseLock).not.toHaveBeenCalled()

    child.emit("close", 1)
    await vi.waitFor(() => expect(releaseLock).toHaveBeenCalledOnce())
    expect(releaseLock).toHaveBeenCalledWith(true)
    expect(completed).toBe(false)

    release.resolve()
    await completion
    expect(completed).toBe(true)
  })
})
