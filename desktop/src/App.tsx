import "./styles.css"
import { FormEvent, useEffect, useState } from "react"

type AuthState = "loading" | "authenticated" | "setup"

export function App() {
  const isPreferencesView = new URLSearchParams(window.location.search).get("view") === "preferences"
  const [authState, setAuthState] = useState<AuthState>("loading")
  const [url, setUrl] = useState("")
  const [token, setToken] = useState("")
  const [error, setError] = useState("")
  const [isSaving, setIsSaving] = useState(false)

  useEffect(() => {
    let isMounted = true

    window.syrusDesktop
      .getCredentials()
      .then((credentials) => {
        if (!isMounted) {
          return
        }

        if (credentials) {
          setUrl(credentials.url)
          setToken(credentials.token)
          setAuthState(isPreferencesView ? "setup" : "authenticated")
        } else {
          setAuthState("setup")
        }
      })
      .catch(() => {
        if (isMounted) {
          setAuthState("setup")
        }
      })

    const unsubscribe = window.syrusDesktop.onCredentialsCleared(() => {
      setToken("")
      setError("")
      setAuthState("setup")
    })

    return () => {
      isMounted = false
      unsubscribe()
    }
  }, [isPreferencesView])

  const saveCredentials = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    setError("")
    setIsSaving(true)

    try {
      const credentials = await window.syrusDesktop.saveCredentials({ url, token })
      setUrl(credentials.url)
      setToken(credentials.token)
      setAuthState("authenticated")
    } catch (saveError) {
      setError(saveError instanceof Error ? saveError.message : "Could not save credentials.")
    } finally {
      setIsSaving(false)
    }
  }

  if (authState === "loading") {
    return (
      <main className="shell">
        <section className="panel panel--status" aria-label="Loading Syrus Desktop">
          <p className="eyebrow">Syrus Desktop</p>
          <h1>Loading</h1>
        </section>
      </main>
    )
  }

  if (authState === "setup") {
    return (
      <main className="shell">
        <section className="panel" aria-label="Syrus Desktop settings">
          <div>
            <p className="eyebrow">Syrus Desktop</p>
            <h1>Connect Syrus</h1>
          </div>

          <form className="settings-form" onSubmit={saveCredentials}>
            <label>
              <span>Syrus instance URL</span>
              <input
                autoFocus
                required
                type="url"
                value={url}
                placeholder="https://your-syrus-instance.com"
                onChange={(event) => setUrl(event.target.value)}
              />
            </label>

            <label>
              <span>API token</span>
              <input
                required
                type="password"
                value={token}
                autoComplete="off"
                onChange={(event) => setToken(event.target.value)}
              />
            </label>

            {error ? <p className="form-error">{error}</p> : null}

            <div className="form-actions">
              <button type="button" className="link-button" onClick={() => window.syrusDesktop.openTokenDocs()}>
                Generate a token
              </button>
              <button type="submit" disabled={isSaving}>
                {isSaving ? "Saving..." : "Save"}
              </button>
            </div>
          </form>
        </section>
      </main>
    )
  }

  return (
    <main className="shell">
      <section className="panel" aria-label="Syrus Desktop shell">
        <div>
          <p className="eyebrow">Syrus Desktop</p>
          <h1>Desktop shell ready</h1>
          <p className="status-line">Connected to {url}</p>
        </div>
      </section>
    </main>
  )
}
