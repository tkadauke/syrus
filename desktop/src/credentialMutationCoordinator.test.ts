import { describe, expect, it } from "vitest"
import { CredentialMutationCoordinator } from "../electron/credentialMutationCoordinator"

const deferred = () => {
  let resolve: () => void = () => {}
  const promise = new Promise<void>((done) => {
    resolve = done
  })
  return { promise, resolve }
}

describe("CredentialMutationCoordinator", () => {
  it("leaves sign-out as the final mutation when provisioning is already validating", async () => {
    const coordinator = new CredentialMutationCoordinator()
    const validation = deferred()
    const mutations: string[] = []
    const provisionGeneration = coordinator.currentGeneration()
    const provision = coordinator.runIfCurrent(provisionGeneration, async () => {
      await validation.promise
      mutations.push("write provisioned credentials")
    })

    await Promise.resolve()
    const signOutGeneration = coordinator.supersede()
    const signOut = coordinator.runIfCurrent(signOutGeneration, async () => {
      mutations.push("delete credentials")
    })
    validation.resolve()

    await expect(provision).resolves.toEqual({ committed: false })
    await expect(signOut).resolves.toMatchObject({ committed: true })
    expect(mutations).toEqual(["write provisioned credentials", "delete credentials"])
  })

  it("leaves a newer manual save as the final mutation", async () => {
    const coordinator = new CredentialMutationCoordinator()
    const blocker = deferred()
    const mutations: string[] = []
    const provisionGeneration = coordinator.currentGeneration()
    const provision = coordinator.runIfCurrent(provisionGeneration, async () => {
      await blocker.promise
      mutations.push("write provisioned credentials")
    })

    await Promise.resolve()
    const manualSaveGeneration = coordinator.supersede()
    const manualSave = coordinator.runIfCurrent(manualSaveGeneration, async () => {
      mutations.push("write manual credentials")
    })
    blocker.resolve()

    await expect(provision).resolves.toEqual({ committed: false })
    await expect(manualSave).resolves.toMatchObject({ committed: true })
    expect(mutations.at(-1)).toBe("write manual credentials")
  })
})
