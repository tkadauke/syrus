import { contextBridge, ipcRenderer } from "electron"

type Credentials = {
  url: string
  token: string
}

contextBridge.exposeInMainWorld("syrusDesktop", {
  getCredentials: () => ipcRenderer.invoke("get-credentials") as Promise<Credentials | null>,
  saveCredentials: (credentials: Credentials) =>
    ipcRenderer.invoke("save-credentials", credentials) as Promise<Credentials>,
  openTokenDocs: () => ipcRenderer.invoke("open-token-docs") as Promise<void>,
  onCredentialsCleared: (callback: () => void) => {
    const listener = () => callback()
    ipcRenderer.on("credentials-cleared", listener)
    return () => ipcRenderer.removeListener("credentials-cleared", listener)
  }
})
