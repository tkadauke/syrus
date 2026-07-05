import { useQuery } from "@tanstack/react-query"
import { useState } from "react"
import type { ReactNode } from "react"
import {
  fetchAdminGithubAppConfirm,
  fetchAdminGithubAppRegister,
  type AdminGithubAppRegisterPayload,
  type AdminGithubAppStatus
} from "../api/adminGithubApp"
import { ApiError } from "../api/client"
import { openInNewTab } from "../lib/desktopShell"
import { useT } from "../hooks/useT"

export function AdminGithubAppRegister() {
  const { t } = useT("admin")
  const registration = useQuery({
    queryKey: ["admin", "github_app", "register"],
    queryFn: () => fetchAdminGithubAppRegister()
  })

  return (
    <main aria-label="GitHub App registration" className="mx-auto max-w-6xl space-y-6 p-6">
      <PageHeader
        title={t("github_app.register_title")}
        description={t("github_app.register_description")}
      />

      {registration.isPending ? <PanelMessage>{t("github_app.loading_register")}</PanelMessage> : null}
      {registration.isError ? <PanelMessage tone="error">{errorMessage(registration.error, t("github_app.error_load_register"))}</PanelMessage> : null}
      {registration.isSuccess ? <RegisterView payload={registration.data} /> : null}
    </main>
  )
}

export function AdminGithubAppConfirm() {
  const { t } = useT("admin")
  const confirmation = useQuery({
    queryKey: ["admin", "github_app", "confirm"],
    queryFn: fetchAdminGithubAppConfirm
  })

  return (
    <main aria-label="GitHub App registered" className="mx-auto max-w-6xl space-y-6 p-6">
      <PageHeader
        title={t("github_app.confirm_title")}
        description={t("github_app.confirm_description")}
      />

      <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
        <h2 className="font-medium text-gray-900 dark:text-gray-100">{t("github_app.next_steps")}</h2>
        <ol className="mt-2 list-decimal space-y-1 pl-5 text-sm text-gray-700 dark:text-gray-200">
          <li>{t("github_app.step_1")}</li>
          <li>{t("github_app.step_2")}</li>
          <li>{t("github_app.step_3")}</li>
        </ol>
      </section>

      {confirmation.isPending ? <PanelMessage>{t("github_app.loading_stored")}</PanelMessage> : null}
      {confirmation.isError ? <PanelMessage tone="error">{errorMessage(confirmation.error, t("github_app.error_load_stored"))}</PanelMessage> : null}
      {confirmation.isSuccess ? <StoredRegistration app={confirmation.data.github_app} /> : null}
    </main>
  )
}

function RegisterView({ payload }: { payload: AdminGithubAppRegisterPayload }) {
  const [popupBlocked, setPopupBlocked] = useState<string | null>(null)
  const { t } = useT("admin")
  return (
    <>
      <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
        <h2 className="font-medium text-gray-900 dark:text-gray-100">{t("github_app.current_status")}</h2>
        <div className="mt-2 text-sm">
          <GithubAppStatus app={payload.github_app} />
        </div>
      </section>

      <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
        <h2 className="font-medium text-gray-900 dark:text-gray-100">{t("github_app.register_with_github")}</h2>
        <p className="mt-1 max-w-prose text-xs text-gray-600 dark:text-gray-300">
          {t("github_app.register_instructions")}
        </p>
        <button
          className="mt-4 rounded bg-blue-600 dark:bg-blue-500 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-500 dark:hover:bg-blue-400"
          type="button"
          onClick={() => setPopupBlocked(openInNewTab(payload.bounce_url) ? null : payload.bounce_url)}
        >
          {payload.submit_label}
        </button>
        {popupBlocked ? (
          <p className="mt-2 text-xs text-amber-700 dark:text-amber-300">
            {/* TODO: missing i18n keys for "Popup blocked.", "Open the registration page", "manually." */}
            Popup blocked.{" "}
            <a className="font-medium underline" href={popupBlocked} rel="noreferrer" target="_blank">
              Open the registration page
            </a>{" "}
            manually.
          </p>
        ) : null}
      </section>
    </>
  )
}

function StoredRegistration({ app }: { app: AdminGithubAppStatus }) {
  const { t } = useT("admin")
  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
      <h2 className="font-medium text-gray-900 dark:text-gray-100">{t("github_app.stored_registration")}</h2>
      <p className="mt-2 text-sm text-gray-600 dark:text-gray-300">
        {app.registered ? (
          <>
            <span className="font-mono">{app.slug || `app-${app.id || "unknown"}`}</span>
            {app.registered_at ? ` registered ${formatDate(app.registered_at)}.` : " registered."}
          </>
        ) : (
          t("github_app.no_stored_registration")
        )}
      </p>
    </section>
  )
}

function GithubAppStatus({ app }: { app: AdminGithubAppStatus }) {
  const { t } = useT("admin")
  if (!app.registered) {
    return <span className="rounded bg-gray-100 dark:bg-gray-800 px-2 py-0.5 font-mono text-xs uppercase text-gray-700 dark:text-gray-200">{t("github_app.not_registered")}</span>
  }

  return (
    <>
      <span className="rounded bg-emerald-100 dark:bg-emerald-950/60 px-2 py-0.5 font-mono text-xs uppercase text-emerald-700 dark:text-emerald-300">{t("github_app.registered")}</span>
      <span className="ml-2 text-gray-600 dark:text-gray-300">{app.slug || `GitHub App #${app.id || "unknown"}`}</span>
    </>
  )
}

function PageHeader({ title, description }: { title: string; description: string }) {
  const { t } = useT("admin")
  return (
    <header className="border-b border-gray-200 dark:border-gray-700 pb-4">
      <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("section_label")}</p>
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
