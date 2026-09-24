type ResetApiClientState = () => void

const RESETTERS_KEY = Symbol.for("syrus.apiClientTestState.resetters")

type GlobalWithApiClientResetters = typeof globalThis & {
  [RESETTERS_KEY]?: Set<ResetApiClientState>
}

function resetters() {
  const global = globalThis as GlobalWithApiClientResetters
  global[RESETTERS_KEY] ??= new Set<ResetApiClientState>()
  return global[RESETTERS_KEY]
}

export function registerApiClientStateResetForTests(reset: ResetApiClientState) {
  resetters().add(reset)
}

export function resetApiClientStateForTests() {
  resetters().forEach((reset) => reset())
}
