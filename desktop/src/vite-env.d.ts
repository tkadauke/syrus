/// <reference types="vite/client" />

type SyrusCredentials = {
  url: string
  token: string
}

interface Window {
  syrusDesktop: {
    getCredentials: () => Promise<SyrusCredentials | null>
    saveCredentials: (credentials: SyrusCredentials) => Promise<SyrusCredentials>
    openTokenDocs: () => Promise<void>
    onCredentialsCleared: (callback: () => void) => () => void
  }
}
