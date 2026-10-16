import { afterEach, describe, expect, it, vi } from "vitest"

vi.mock("electron", () => ({
  app: { getPath: () => "/tmp", isPackaged: false },
  dialog: {},
  shell: { openExternal: vi.fn() }
}))

vi.mock("../electron/settings.js", () => ({
  currentStackIdentity: () => ({
    channel: "stable",
    dataVolume: "data",
    searchVolume: "search",
    project: "syrus",
    defaultPort: 3000
  }),
  localStateDir: () => "/tmp/syrus-test-state",
  saveBackendConfig: vi.fn(),
  setOnboardingResumeLocal: vi.fn()
}))

import { OnboardingDriver, type OnboardingState } from "../electron/installer/installerDriver"

const deferred = <T>() => {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((done) => {
    resolve = done
  })
  return { promise, resolve }
}

afterEach(() => {
  vi.useRealTimers()
})

describe("OnboardingDriver asynchronous ownership", () => {
  it("claims a runtime install before creating its temp directory and honors Back during that await", async () => {
    const directory = deferred<string>()
    const states: OnboardingState[] = []
    const createRuntimeInstallerDir = vi.fn(() => directory.promise)
    const driver = new OnboardingDriver({ onState: (state) => states.push(state), onLogLine: () => {}, createRuntimeInstallerDir }, "win32")
    ;(driver as unknown as { state: OnboardingState }).state = {
      phase: "local.runtimeMissing",
      polling: false,
      wslMissing: false,
      installError: null
    }

    const first = driver.installRuntime()
    const second = driver.installRuntime()

    expect(createRuntimeInstallerDir).toHaveBeenCalledTimes(1)
    expect(driver.getState()).toMatchObject({ phase: "local.runtimeInstalling", step: "downloading" })

    driver.backToWelcome()
    directory.resolve("/tmp/nonexistent-syrus-installer-test")
    await Promise.all([first, second])

    expect(driver.getState()).toEqual({ phase: "welcome" })
    expect(states.at(-1)).toEqual({ phase: "welcome" })
  })

  it("aborts the running Docker Desktop child when Back is clicked during installation", async () => {
    let childSignal: AbortSignal | undefined
    const runRuntimeInstaller = vi.fn((_path: string, signal?: AbortSignal) => {
      childSignal = signal
      return new Promise<void>((_resolve, reject) => {
        signal?.addEventListener("abort", () => reject(signal.reason), { once: true })
      })
    })
    const driver = new OnboardingDriver(
      {
        onState: () => {},
        onLogLine: () => {},
        createRuntimeInstallerDir: vi.fn().mockResolvedValue("/tmp/nonexistent-syrus-installer-child-test"),
        downloadRuntimeInstaller: vi.fn().mockResolvedValue(undefined),
        verifyRuntimeInstaller: vi.fn().mockResolvedValue(undefined),
        runRuntimeInstaller
      },
      "win32"
    )
    ;(driver as unknown as { state: OnboardingState }).state = {
      phase: "local.runtimeMissing",
      polling: false,
      wslMissing: false,
      installError: null
    }

    const install = driver.installRuntime()
    await vi.waitFor(() => expect(runRuntimeInstaller).toHaveBeenCalledTimes(1))
    expect(driver.getState()).toMatchObject({ phase: "local.runtimeInstalling", step: "installing" })

    driver.backToWelcome()
    await install

    expect(childSignal?.aborted).toBe(true)
    expect(driver.getState()).toEqual({ phase: "welcome" })
  })

  it("does not let a negative probe from a stopped generation clear or re-arm the current poll", async () => {
    vi.useFakeTimers()
    const oldBinary = deferred<string | null>()
    const findDockerBinary = vi
      .fn<() => Promise<string | null>>()
      .mockImplementationOnce(() => oldBinary.promise)
      .mockResolvedValue(null)
    const driver = new OnboardingDriver({
      onState: () => {},
      onLogLine: () => {},
      findDockerBinary,
      daemonUp: vi.fn().mockResolvedValue(false)
    })
    const pollForDaemon = (driver as unknown as { pollForDaemon: (maxPolls: number) => Promise<boolean | null> }).pollForDaemon.bind(driver)

    const stalePoll = pollForDaemon(1)
    const currentPoll = pollForDaemon(2)
    expect(await stalePoll).toBeNull()

    oldBinary.resolve("docker")
    await Promise.resolve()
    await vi.advanceTimersByTimeAsync(2_000)

    await expect(currentPoll).resolves.toBe(false)
    expect(findDockerBinary).toHaveBeenCalledTimes(3)
  })
})
