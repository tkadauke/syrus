import { useQuery } from "@tanstack/react-query"
import type { ReactNode } from "react"
import {
  fetchAdminGithubAppConfirm,
  fetchAdminGithubAppRegister,
  type AdminGithubAppRegisterPayload,
  type AdminGithubAppStatus
} from "../api/adminGithubApp"
import { ApiError } from "../api/client"

export function AdminGithubAppRegister() {
  const registration = useQuery({
    queryKey: ["admin", "github_app", "register"],
    queryFn: fetchAdminGithubAppRegister
  })

  return (
    <main aria-label="GitHub App registration" className="mx-auto max-w-5xl space-y-6 p-6">
      <PageHeader
        title="GitHub App registration"
        description="Register the singleton Syrus GitHub App. Repositories use App credentials only after the App is installed on their GitHub account or repository."
      />

      {registration.isPending ? <PanelMessage>Loading registration form...</PanelMessage> : null}
      {registration.isError ? <PanelMessage tone="error">{errorMessage(registration.error, "Unable to load GitHub App registration.")}</PanelMessage> : null}
      {registration.isSuccess ? <RegisterView payload={registration.data} /> : null}
    </main>
  )
}

export function AdminGithubAppConfirm() {
  const confirmation = useQuery({
    queryKey: ["admin", "github_app", "confirm"],
    queryFn: fetchAdminGithubAppConfirm
  })

  return (
    <main aria-label="GitHub App registered" className="mx-auto max-w-5xl space-y-6 p-6">
      <PageHeader
        title="GitHub App registered"
        description="Syrus stored the App credentials and queued an installation sync."
      />

      <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
        <h2 className="font-medium text-gray-900 dark:text-gray-100">Next steps</h2>
        <ol className="mt-2 list-decimal space-y-1 pl-5 text-sm text-gray-700 dark:text-gray-200">
          <li>Install the App on your repositories via GitHub.</li>
          <li>Wait for the installation sync, or let the 5-minute recurring sync pick it up.</li>
          <li>Keep a personal access token configured for repositories that do not have an active App installation.</li>
        </ol>
      </section>

      {confirmation.isPending ? <PanelMessage>Loading stored registration...</PanelMessage> : null}
      {confirmation.isError ? <PanelMessage tone="error">{errorMessage(confirmation.error, "Unable to load stored registration.")}</PanelMessage> : null}
      {confirmation.isSuccess ? <StoredRegistration app={confirmation.data.github_app} /> : null}
    </main>
  )
}

function RegisterView({ payload }: { payload: AdminGithubAppRegisterPayload }) {
  return (
    <>
      <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
        <h2 className="font-medium text-gray-900 dark:text-gray-100">Current status</h2>
        <div className="mt-2 text-sm">
          <GithubAppStatus app={payload.github_app} />
        </div>
      </section>

      <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
        <h2 className="font-medium text-gray-900 dark:text-gray-100">Register with GitHub</h2>
        <p className="mt-1 max-w-prose text-xs text-gray-600 dark:text-gray-300">
          GitHub will create the App from the manifest, then redirect back here with temporary credentials. Registration alone does not grant repository access; install the App after registration.
        </p>
        <form
          action={payload.github_manifest_url}
          aria-label="GitHub manifest registration"
          className="mt-4"
          method="post"
          rel="noopener"
          target="_blank"
        >
          <input name="manifest" type="hidden" value={payload.manifest} />
          <button
            className="rounded bg-blue-600 dark:bg-blue-500 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-500 dark:hover:bg-blue-400"
            formTarget="_blank"
            type="submit"
          >
            {payload.submit_label}
          </button>
        </form>
      </section>
    </>
  )
}

function StoredRegistration({ app }: { app: AdminGithubAppStatus }) {
  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
      <h2 className="font-medium text-gray-900 dark:text-gray-100">Stored registration</h2>
      <p className="mt-2 text-sm text-gray-600 dark:text-gray-300">
        {app.registered ? (
          <>
            <span className="font-mono">{app.slug || `app-${app.id || "unknown"}`}</span>
            {app.registered_at ? ` registered ${formatDate(app.registered_at)}.` : " registered."}
          </>
        ) : (
          "No GitHub App registration is stored."
        )}
      </p>
    </section>
  )
}

function GithubAppStatus({ app }: { app: AdminGithubAppStatus }) {
  if (!app.registered) {
    return <span className="rounded bg-gray-100 dark:bg-gray-800 px-2 py-0.5 font-mono text-xs uppercase text-gray-700 dark:text-gray-200">not registered</span>
  }

  return (
    <>
      <span className="rounded bg-emerald-100 dark:bg-emerald-950/60 px-2 py-0.5 font-mono text-xs uppercase text-emerald-700 dark:text-emerald-300">registered</span>
      <span className="ml-2 text-gray-600 dark:text-gray-300">{app.slug || `GitHub App #${app.id || "unknown"}`}</span>
    </>
  )
}

function PageHeader({ title, description }: { title: string; description: string }) {
  return (
    <header className="border-b border-gray-200 dark:border-gray-700 pb-4">
      <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">Admin</p>
      <h1 className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">{title}</h1>
      <p className="mt-1 text-sm text-gray-500 dark:text-gray-400">{description}</p>
    </header>
  )
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <section className={`rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4 text-sm ${tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-600 dark:text-gray-300"}`}>{children}</section>
}

function errorMessage(error: Error, fallback: string) {
  if (error instanceof ApiError) return error.message
  return fallback
}

function formatDate(value: string) {
  return new Date(value).toLocaleString()
}
