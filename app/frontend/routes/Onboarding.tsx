import { withRoutePrefix } from "../lib/routing"
import { PageHeading } from "../components/Heading"
import { useState } from "react"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import { Link, useLocation, useNavigate } from "react-router-dom"
import type { BootstrapPayload } from "../api/bootstrap"
import { startOnboardingChat } from "../api/chats"
import { GithubTokenModal } from "../components/GithubTokenModal"
import { ConfigureAgentModal } from "../components/ConfigureAgentModal"
import { AddRepositoryModal } from "../components/AddRepositoryModal"
import { buttonClasses } from "../components/Button"
import { useT } from "../hooks/useT"
import type { TFunction } from "i18next"
import { fetchRepositoryReadiness } from "../api/repositories"
import { RepositoryReadinessModal, readinessTone } from "../components/RepositoryReadinessModal"

type SetupStatus = NonNullable<BootstrapPayload["setup_status"]>

type ChecklistStep = {
  key: string
  title: string
  detail: string
  complete: boolean
  ctaLabel: string
  ctaPath: string
  // When set, the CTA opens an in-page flow instead of navigating away.
  ctaModal?: "github_token" | "configure_agent" | "add_repository"
  // When set, the CTA runs an action (and may navigate away) instead of linking.
  ctaAction?: "start_chat"
  // Once the step is complete, prefer linking here over reopening ctaModal
  // (e.g. a management page rather than an "add new" form).
  editPath?: string
  // Label for the CTA once the step is already complete. Defaults to a
  // generic "Edit" when omitted.
  editLabel?: string
}

export function OnboardingRoute({ bootstrap }: { bootstrap: BootstrapPayload | null | undefined }) {
  const { t } = useT("common")
  const location = useLocation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [openModal, setOpenModal] = useState<ChecklistStep["ctaModal"] | "readiness" | null>(null)
  const [startingChat, setStartingChat] = useState(false)
  const [chatError, setChatError] = useState<string | null>(null)
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const setup = bootstrap?.setup_status
  const user = bootstrap?.current_user
  const repositoryId = setup?.onboarding_repository_id
  const readiness = useQuery({
    queryKey: ["repository-readiness", repositoryId],
    queryFn: () => fetchRepositoryReadiness(repositoryId!),
    enabled: Boolean(repositoryId),
    staleTime: 60_000,
    refetchInterval: (query) => {
      const status = query.state.data?.readiness.execution_probe?.status
      return status === "queued" || status === "running" ? 1_000 : false
    }
  })

  if (!user || !setup) {
    return (
      <main aria-label={t("onboarding_aria")} className="mx-auto max-w-5xl p-6">
        <p className="text-sm text-gray-600 dark:text-gray-400">{t("onboarding.loading")}</p>
      </main>
    )
  }

  async function launchChat() {
    setChatError(null)
    setStartingChat(true)
    try {
      const result = await startOnboardingChat()
      // Refresh bootstrap so the chrome reveals the other nav tabs (gated on
      // setup.chat_started) without needing a page reload.
      await queryClient.invalidateQueries({ queryKey: ["bootstrap"] })
      navigate(withRoutePrefix(result.redirect_to, prefix))
    } catch {
      setChatError(t("onboarding.chat_start_error"))
      setStartingChat(false)
    }
  }

  const steps = checklistSteps(setup, user, t)
  const activeStep = steps.find((step) => !step.complete)
  const complete = !activeStep
  const dashboardPath = "/dashboard/jobs?view=list"

  return (
    <main aria-label={t("onboarding_aria")} className="mx-auto max-w-5xl space-y-6 p-6">
      <header className="border-b border-gray-200 dark:border-gray-700 pb-5">
        <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("onboarding.setup_label")}</p>
        <PageHeading className="mt-2">{t("onboarding.heading")}</PageHeading>
      </header>

      <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
        <ol className="divide-y divide-gray-200 dark:divide-gray-700">
          {steps.map((step) => {
            const current = activeStep?.key === step.key
            const showDetail = current || (step.key === "agent" && step.complete)
            return (
              <li className={checklistItemClass(current)} key={step.key}>
                <div className={checklistContentClass(current)}>
                  <span className={statusMarkerClass(step.complete, current)}>{step.complete ? t("onboarding.complete_marker") : current ? ">" : ""}</span>
                  <div className={current ? "min-w-0 text-center" : "min-w-0"}>
                    <h2 className="text-sm font-medium text-gray-900 dark:text-gray-100">{step.title}</h2>
                    {showDetail ? (
                      <p className={current ? "mt-2 max-w-xl text-sm text-gray-600 dark:text-gray-400" : "mt-1 text-xs text-gray-500 dark:text-gray-400"}>
                        {step.detail}
                      </p>
                    ) : null}
                  </div>
                </div>
                <div className="flex shrink-0 flex-col items-end gap-2 sm:flex-row sm:items-center">
                  {step.key === "repository" && step.complete && readiness.data ? (
                    <button
                      className={`rounded-full px-2.5 py-1 text-xs font-medium ring-1 ring-inset ${readinessTriggerClass(readinessTone(readiness.data.readiness.status))}`}
                      onClick={() => setOpenModal("readiness")}
                      type="button"
                    >
                      {readiness.data.readiness.summary}
                    </button>
                  ) : null}
                  {step.complete ? (
                    <span className="rounded bg-green-50 dark:bg-green-950/40 px-2.5 py-1 text-xs font-medium text-green-700 dark:text-green-300">
                      {t("onboarding.complete_badge")}
                    </span>
                  ) : null}
                  {step.complete && step.editPath ? (
                    <Link className={secondaryCtaClass()} to={withRoutePrefix(step.editPath, prefix)}>
                      {step.editLabel ?? t("onboarding.edit_label")}
                    </Link>
                  ) : step.ctaModal ? (
                    <button
                      className={step.complete ? secondaryCtaClass() : primaryCtaClass(current)}
                      onClick={() => setOpenModal(step.ctaModal ?? null)}
                      type="button"
                    >
                      {step.complete ? (step.editLabel ?? t("onboarding.edit_label")) : step.ctaLabel}
                    </button>
                  ) : step.ctaAction === "start_chat" ? (
                    <button
                      className={step.complete ? secondaryCtaClass() : primaryCtaClass(current)}
                      disabled={startingChat}
                      onClick={launchChat}
                      type="button"
                    >
                      {startingChat ? t("onboarding.opening_chat") : step.ctaLabel}
                    </button>
                  ) : (
                    <Link className={step.complete ? secondaryCtaClass() : primaryCtaClass(current)} to={withRoutePrefix(step.ctaPath, prefix)}>
                      {step.ctaLabel}
                    </Link>
                  )}
                </div>
              </li>
            )
          })}
        </ol>
      </section>

      {chatError ? (
        <p
          className="rounded border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300"
          role="alert"
        >
          {chatError}
        </p>
      ) : null}

      {complete ? (
        <section className="rounded border border-green-200 dark:border-green-800 bg-green-50 dark:bg-green-950/40 p-4">
          <h2 className="text-sm font-medium text-green-900 dark:text-green-100">{t("onboarding.ready_heading")}</h2>
          <p className="mt-1 text-sm text-green-800 dark:text-green-200">{t("onboarding.ready_description")}</p>
          <Link
            className="mt-3 inline-flex rounded bg-green-700 px-3 py-2 text-sm font-medium text-white hover:bg-green-800"
            to={withRoutePrefix(dashboardPath, prefix)}
          >
            {t("onboarding.open_dashboard")}
          </Link>
        </section>
      ) : null}

      {openModal === "github_token" ? <GithubTokenModal onClose={() => setOpenModal(null)} /> : null}
      {openModal === "configure_agent" ? <ConfigureAgentModal onClose={() => setOpenModal(null)} /> : null}
      {openModal === "add_repository" ? <AddRepositoryModal onClose={() => setOpenModal(null)} /> : null}
      {openModal === "readiness" && repositoryId && readiness.data ? (
        <RepositoryReadinessModal onClose={() => setOpenModal(null)} open repositoryId={repositoryId} report={readiness.data.readiness} />
      ) : null}
    </main>
  )
}

function readinessTriggerClass(tone: "green" | "amber" | "red") {
  if (tone === "green") return "bg-green-50 text-green-700 ring-green-600/20 dark:bg-green-950/40 dark:text-green-300"
  if (tone === "amber") return "bg-amber-50 text-amber-700 ring-amber-600/20 dark:bg-amber-950/40 dark:text-amber-300"
  return "bg-red-50 text-red-700 ring-red-600/20 dark:bg-red-950/40 dark:text-red-300"
}

function checklistSteps(setup: SetupStatus, user: NonNullable<BootstrapPayload["current_user"]>, t: TFunction): ChecklistStep[] {
  return [
    {
      key: "account",
      title: t("onboarding.account_title"),
      detail: user.admin ? t("onboarding.account_admin", { name: user.display_name }) : t("onboarding.account_needs_admin"),
      complete: user.admin,
      ctaLabel: t("onboarding.account_cta"),
      ctaPath: "/profile"
    },
    {
      key: "github",
      title: t("onboarding.github_title"),
      detail: githubStepDetail(setup, t),
      complete: setup.credential_status.github,
      ctaLabel: t("onboarding.github_cta"),
      ctaPath: "/credentials",
      ctaModal: "github_token",
      editLabel: t("onboarding.github_edit")
    },
    {
      key: "agent",
      title: t("onboarding.agent_title"),
      detail: setup.credential_status.agent
        ? t("onboarding.agent_ready", { provider: setup.credential_status.active_agent_provider_label || providerLabel(setup.credential_status.active_agent_provider) })
        : t("onboarding.agent_missing"),
      complete: setup.credential_status.agent,
      ctaLabel: t("onboarding.agent_cta"),
      ctaPath: "/credentials",
      ctaModal: "configure_agent",
      editLabel: t("onboarding.agent_edit")
    },
    {
      key: "repository",
      title: t("onboarding.repository_title"),
      detail: setup.repository_configured
        ? t("onboarding.repository_configured", { count: setup.counts.repositories })
        : t("onboarding.repository_missing"),
      complete: setup.repository_configured,
      ctaLabel: t("onboarding.repository_cta"),
      ctaPath: "/repositories/new",
      ctaModal: "add_repository",
      // Reopening the "add repository" modal wouldn't let the user manage
      // repos they already added — send them to the management page instead.
      editPath: "/repositories",
      editLabel: t("onboarding.repository_edit")
    },
    {
      key: "chat",
      title: t("onboarding.chat_title"),
      detail: setup.onboarding_chat_started
        ? t("onboarding.chat_started")
        : t("onboarding.chat_missing"),
      complete: setup.onboarding_chat_started,
      ctaLabel: setup.onboarding_chat_started ? t("onboarding.chat_open") : t("onboarding.chat_start"),
      ctaPath: "/onboarding",
      ctaAction: "start_chat"
    },
    {
      key: "epic",
      title: t("onboarding.epic_title"),
      detail: epicStepDetail(setup, t),
      complete: setup.first_epic_landed,
      ctaLabel: t("onboarding.chat_open"),
      ctaPath: "/onboarding",
      ctaAction: "start_chat"
    }
  ]
}

function epicStepDetail(setup: SetupStatus, t: TFunction) {
  if (setup.first_epic_landed) return t("onboarding.epic_landed")
  if (setup.first_epic_started) return t("onboarding.epic_started")
  if (setup.first_epic_created) return t("onboarding.epic_created")
  return t("onboarding.epic_missing")
}

function githubStepDetail(setup: SetupStatus, t: TFunction) {
  const status = setup.credential_status
  if (status.github) return t("onboarding.github_connected")
  if (status.github_pat) return t("onboarding.github_needs_app")
  if (status.github_app) return t("onboarding.github_needs_token")
  return t("onboarding.github_missing")
}

function providerLabel(provider: SetupStatus["credential_status"]["active_agent_provider"]) {
  if (provider === "agy") return "Antigravity"
  if (provider === "codex") return "Codex"
  if (provider === "claude") return "Claude"

  return provider.replace(/_/g, " ").replace(/\b\w/g, (match) => match.toUpperCase())
}

function statusMarkerClass(complete: boolean, current: boolean) {
  if (complete) return "mt-0.5 inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-green-600 text-xs font-semibold text-white"
  if (current) return "mt-0.5 inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-brand text-lg leading-none text-on-brand"

  return "mt-0.5 inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-full border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900"
}

function checklistItemClass(current: boolean) {
  if (current) return "flex flex-col items-center gap-4 p-5 text-center sm:p-6"

  return "flex flex-col gap-3 p-3 sm:flex-row sm:items-center sm:justify-between sm:p-4"
}

function checklistContentClass(current: boolean) {
  if (current) return "flex min-w-0 flex-col items-center gap-3"

  return "flex min-w-0 items-center gap-3"
}

function primaryCtaClass(current: boolean) {
  const base = "inline-flex shrink-0 justify-center rounded px-3 py-2 text-sm font-medium"
  return current
    ? buttonClasses("primary", "md", "min-w-48 shrink-0 justify-center")
    : `${base} border border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800`
}

// Small text-style action for revisiting an already-completed step, shown
// next to the "Complete" badge instead of the full-size primary CTA.
function secondaryCtaClass() {
  return "inline-flex shrink-0 justify-center rounded px-2 py-1 text-xs font-medium text-brand dark:text-brand-emphasis hover:underline"
}
