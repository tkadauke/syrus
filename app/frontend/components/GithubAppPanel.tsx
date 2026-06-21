import { useEffect, useState } from "react"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import { fetchAdminGithubAppConfirm, fetchAdminGithubAppRegister } from "../api/adminGithubApp"
import { ApiError } from "../api/client"

// Admin-only panel: create the singleton Syrus GitHub App from a manifest,
// then install it. Registering the App satisfies the GitHub onboarding step.
export function GithubAppPanel({ onClose, onSaved }: { onClose: () => void; onSaved?: () => void }) {
  const queryClient = useQueryClient()
  const [awaiting, setAwaiting] = useState(false)

  // Fetched once: generates the manifest + the session state GitHub echoes
  // back to the callback. Refetching would rotate that state, so keep it stable.
  const register = useQuery({
    queryKey: ["admin", "github_app", "register", "onboarding"],
    queryFn: () => fetchAdminGithubAppRegister("onboarding"),
    staleTime: Number.POSITIVE_INFINITY,
    refetchOnWindowFocus: false
  })

  // Polled while we wait for GitHub to redirect through the callback.
  const confirm = useQuery({
    queryKey: ["admin", "github_app", "confirm"],
    queryFn: fetchAdminGithubAppConfirm,
    refetchInterval: awaiting ? 3000 : false,
    refetchOnWindowFocus: true
  })

  const status = confirm.data?.github_app ?? register.data?.github_app
  const registered = !!status?.registered
  const installUrl = status?.install_url ?? null

  // Once the App is registered, the GitHub step is satisfied — refresh
  // bootstrap so the checklist marks it complete, and stop polling.
  useEffect(() => {
    if (!registered) return
    setAwaiting(false)
    void queryClient.invalidateQueries({ queryKey: ["bootstrap"] })
    onSaved?.()
  }, [registered])

  if (register.isPending) {
    return <p className="text-sm text-gray-500 dark:text-gray-400">Loading GitHub App registration…</p>
  }

  if (register.isError) {
    const forbidden = register.error instanceof ApiError && register.error.status === 403
    return (
      <Box tone="muted">
        {forbidden
          ? "Only an admin can register the Syrus GitHub App. Ask an admin to set it up, or use a personal access token instead."
          : "Could not load GitHub App registration. Use a personal access token instead."}
      </Box>
    )
  }

  if (registered) {
    return (
      <div className="space-y-4">
        <Box tone="ok">The Syrus GitHub App is registered. Install it on the repositories Syrus should manage.</Box>
        <ol className="space-y-2 text-sm text-gray-700 dark:text-gray-300">
          <li>
            {installUrl ? (
              <a className="inline-flex items-center gap-1 rounded bg-gray-900 px-3 py-2 text-sm font-medium text-white hover:bg-gray-700 dark:bg-gray-100 dark:text-gray-900 dark:hover:bg-white" href={installUrl} rel="noreferrer" target="_blank">
                Install the Syrus App on GitHub <span aria-hidden="true">↗</span>
              </a>
            ) : (
              <span className="text-gray-500 dark:text-gray-400">Install the App from its GitHub settings before adding repositories to Syrus.</span>
            )}
          </li>
        </ol>
        <div className="flex justify-end">
          <button className="rounded-md bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-700" onClick={onClose} type="button">
            Done
          </button>
        </div>
      </div>
    )
  }

  return (
    <div className="space-y-4 text-sm text-gray-700 dark:text-gray-300">
      <p className="text-gray-600 dark:text-gray-400">
        The GitHub App enables actions to appear as a bot natively on your repositories.
      </p>
      <ol className="space-y-2">
        <li><span className="font-medium text-gray-900 dark:text-gray-100">1.</span> Create the App on GitHub (opens a new tab).</li>
        <li><span className="font-medium text-gray-900 dark:text-gray-100">2.</span> You'll be redirected back here; then install it on your repositories.</li>
      </ol>

      <form action={register.data.github_manifest_url} method="post" rel="noopener" target="_blank" onSubmit={() => setAwaiting(true)}>
        <input name="manifest" type="hidden" value={register.data.manifest} />
        <button className="inline-flex items-center gap-1 rounded bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-700" type="submit">
          {register.data.submit_label} <span aria-hidden="true">↗</span>
        </button>
      </form>

      {awaiting ? (
        <p className="flex items-center gap-2 text-sm text-gray-500 dark:text-gray-400" role="status">
          <Spinner /> Waiting for GitHub to finish creating the App…
        </p>
      ) : null}
    </div>
  )
}

function Box({ tone, children }: { tone: "ok" | "muted"; children: React.ReactNode }) {
  const toneClass = tone === "ok"
    ? "border-green-200 bg-green-50 text-green-800 dark:border-green-900 dark:bg-green-950/40 dark:text-green-300"
    : "border-gray-200 bg-gray-50 text-gray-600 dark:border-gray-700 dark:bg-gray-800/50 dark:text-gray-400"
  return <p className={`rounded border px-3 py-2 text-sm ${toneClass}`} role={tone === "ok" ? "status" : undefined}>{children}</p>
}

function Spinner() {
  return (
    <svg aria-hidden="true" className="h-4 w-4 animate-spin text-gray-400" fill="none" viewBox="0 0 24 24">
      <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
      <path className="opacity-75" d="M4 12a8 8 0 018-8" fill="currentColor" />
    </svg>
  )
}
