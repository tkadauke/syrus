import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { PageHeading } from "../components/Heading"
import { useQuery } from "@tanstack/react-query"
import { useState } from "react"
import type { ReactNode } from "react"
import {
  fetchAdminGithubAppConfirm,
  fetchAdminGithubAppRegister,
  type AdminGithubAppRegisterPayload,
  type AdminGithubAppStatus
} from "../api/adminGithubApp"
import { openInNewTab } from "../lib/desktopShell"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"
import { Button } from "../components/Button"

export function AdminGithubAppRegister() {
  const { t } = useT("admin")
  const registration = useQuery({
    queryKey: ["admin", "github_app", "register"],
    queryFn: () => fetchAdminGithubAppRegister()
  })

  return (
    <main aria-label={t("aria_github_registration")} className="mx-auto max-w-6xl space-y-6 p-6">
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
    <main aria-label={t("aria_github_registered")} className="mx-auto max-w-6xl space-y-6 p-6">
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
        <Button
          className="mt-4"
          onClick={() => setPopupBlocked(openInNewTab(payload.bounce_url) ? null : payload.bounce_url)}
          variant="primary"
        >
          {payload.submit_label}
        </Button>
        {popupBlocked ? (
          <p className="mt-2 text-xs text-amber-700 dark:text-amber-300">
            {t("github_app.popup_blocked_prefix")}{" "}
            <a className="font-medium underline" href={popupBlocked} rel="noreferrer" target="_blank">
              {t("github_app.popup_blocked_link")}
            </a>{" "}
            {t("github_app.popup_blocked_suffix")}
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
            {app.registered_at ? <> registered <RelativeTimestamp value={app.registered_at} />.</> : " registered."}
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
      <PageHeading className="mt-1">{title}</PageHeading>
      <p className="mt-1 text-sm text-gray-500 dark:text-gray-400">{description}</p>
    </header>
  )
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <section className={`rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4 text-sm ${tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-600 dark:text-gray-300"}`}>{children}</section>
}


