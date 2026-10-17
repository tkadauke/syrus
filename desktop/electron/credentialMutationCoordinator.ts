export type MutationResult<T> = { committed: true; value: T } | { committed: false }

// Credential file operations contain awaits, but user intent is ordered at
// invocation time. A newer save/sign-out supersedes an older operation while
// this queue ensures the newer operation is always the final disk mutation.
export class CredentialMutationCoordinator {
  private generation = 0
  private tail: Promise<void> = Promise.resolve()

  currentGeneration() {
    return this.generation
  }

  supersede() {
    this.generation += 1
    return this.generation
  }

  async runIfCurrent<T>(generation: number, operation: () => Promise<T>): Promise<MutationResult<T>> {
    const previous = this.tail
    let release: () => void = () => {}
    this.tail = new Promise<void>((resolve) => {
      release = resolve
    })

    await previous
    try {
      if (generation !== this.generation) {
        return { committed: false }
      }

      const value = await operation()
      if (generation !== this.generation) {
        return { committed: false }
      }

      return { committed: true, value }
    } finally {
      release()
    }
  }
}
