import { withRoutePrefix } from "../lib/routing"
import { PageHeading } from "../components/Heading"
import { useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Link, useLocation, useNavigate } from "react-router-dom"
import type { BootstrapPayload } from "../api/bootstrap"
import { fetchSetup, type FullSetupStatusPayload } from "../api/setup"
import { startOnboardingChat } from "../api/chats"
import { GithubTokenModal } from "../components/GithubTokenModal"
import { ConfigureAgentModal } from "../components/ConfigureAgentModal"
import { AddRepositoryModal } from "../components/AddRepositoryModal"
import { buttonClasses } from "../components/Button"
import { useT } from "../hooks/useT"
import type { TFunction } from "i18next"
import { fetchRepositoryReadiness, fetchRepositoryReadinessProbe, fetchRepositoryReadinessSummary } from "../api/repositories"
import { RepositoryReadinessModal, readinessTone } from "../components/RepositoryReadinessModal"
import { applyStartingPermissionProfile, fetchPermissions } from "../api/permissions"
import { Surface } from "../components/ui"

type SetupStatus = FullSetupStatusPayload

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
  const setupQuery = useQuery({ queryKey: ["setup"], queryFn: fetchSetup, staleTime: 30_000 })
  const permissionsQuery = useQuery({ queryKey: ["permissions"], queryFn: fetchPermissions, staleTime: 30_000 })
  const applyProfile = useMutation({
    mutationFn: applyStartingPermissionProfile,
    onSuccess: (result) => {
      queryClient.setQueryData<Awaited<ReturnType<typeof fetchPermissions>>>(["permissions"], (current) =>
        current
          ? {
              ...current,
              current_profiles: result.subject_selector_types.reduce(
                (profiles, subject) => ({ ...profiles, [subject]: result.profile }),
                current.current_profiles
              )
            }
          : current
      )
    }
  })
  const setup = setupQuery.data
  const user = bootstrap?.current_user
  const repositoryId = setup?.onboarding_repository_id
  const readinessSummary = useQuery({
    queryKey: ["repository-readiness-summary", repositoryId],
    queryFn: () => fetchRepositoryReadinessSummary(repositoryId!),
    enabled: Boolean(repositoryId),
    staleTime: 60_000
  })
  const readiness = useQuery({
    queryKey: ["repository-readiness", repositoryId],
    queryFn: () => fetchRepositoryReadiness(repositoryId!),
    enabled: Boolean(repositoryId) && openModal === "readiness",
    staleTime: 60_000
  })
  const readinessProbe = useQuery({
    queryKey: ["repository-readiness-probe", repositoryId],
    queryFn: () => fetchRepositoryReadinessProbe(repositoryId!),
    enabled:
      Boolean(repositoryId) &&
      (readiness.data?.readiness?.execution_probe?.status === "queued" || readiness.data?.readiness?.execution_probe?.status === "running"),
    refetchInterval: (query) => {
      const status = query.state.data?.execution_probe?.status
      return status === "queued" || status === "running" ? Math.min(1_000 * 2 ** query.state.dataUpdateCount, 8_000) : false
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
      queryClient.setQueryData<BootstrapPayload>(["bootstrap"], (current) =>
        current?.setup ? { ...current, setup: { ...current.setup, chat_started: true, onboarding_chat_started: true } } : current
      )
      await queryClient.invalidateQueries({ queryKey: ["setup"] })
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

      <Surface aria-labelledby="onboarding-permission-profile" padding="md" role="region">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="max-w-3xl">
            <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100" id="onboarding-permission-profile">
              {t("onboarding.permission_title")}
            </h2>
            <p className="mt-2 text-sm text-gray-600 dark:text-gray-400">{t("onboarding.permission_intro")}</p>
            <p className="mt-2 text-sm text-gray-600 dark:text-gray-400">{t("onboarding.permission_enforced")}</p>
          </div>
          <Link className={secondaryCtaClass()} to={withRoutePrefix("/settings/permissions", prefix)}>
            {t("onboarding.permission_change_later")}
          </Link>
        </div>
        {permissionsQuery.data ? (
          <div className="mt-4 grid gap-3 md:grid-cols-3">
            {permissionsQuery.data.profiles.map((profile) => {
              const activeEverywhere = ["interactive_chat", "coding_chat", "local_chat"].every(
                (subject) => permissionsQuery.data.current_profiles[subject] === profile.key
              )
              const name = t(`onboarding.permission_profiles.${profileSlug(profile.key)}.name`)
              return (
                <article
                  className={`rounded-lg border p-4 ${activeEverywhere ? "border-brand bg-brand-subtle" : "border-gray-200 dark:border-gray-700"}`}
                  key={profile.key}
                >
                  <div className="flex items-center justify-between gap-2">
                    <h3 className="font-semibold text-gray-900 dark:text-gray-100">{name}</h3>
                    {activeEverywhere ? <span className="text-xs font-medium text-brand">{t("onboarding.permission_selected")}</span> : null}
                  </div>
                  <p className="mt-2 text-sm text-gray-600 dark:text-gray-400">{t(`onboarding.permission_profiles.${profileSlug(profile.key)}.tradeoff`)}</p>
                  <button
                    className="mt-4 rounded border border-brand px-3 py-2 text-sm font-medium text-brand disabled:opacity-60"
                    disabled={activeEverywhere || applyProfile.isPending || setup.first_epic_landed}
                    onClick={() => applyProfile.mutate(profile.key)}
                    type="button"
                  >
                    {activeEverywhere ? t("onboarding.permission_selected") : t("onboarding.permission_choose", { profile: name })}
                  </button>
                </article>
              )
            })}
          </div>
        ) : null}
        <p className="mt-4 text-xs text-gray-500 dark:text-gray-400">{t("onboarding.permission_skip")}</p>
        {applyProfile.isError ? (
          <p className="mt-3 text-sm text-red-700 dark:text-red-300" role="alert">
            {t("onboarding.permission_error")}
          </p>
        ) : null}
      </Surface>

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
                  {step.key === "repository" && step.complete && readinessSummary.data ? (
                    <button
                      className={`rounded-full px-2.5 py-1 text-xs font-medium ring-1 ring-inset ${readinessTriggerClass(readinessTone(readinessSummary.data.readiness.status))}`}
                      onClick={() => setOpenModal("readiness")}
                      type="button"
                    >
                      {readinessSummary.data.readiness.summary}
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
        <Surface padding="sm" role="alert" variant="danger">
          <p className="text-sm">{chatError}</p>
        </Surface>
      ) : null}

      {complete ? (
        <Surface padding="md" variant="success">
          <h2 className="text-sm font-medium">{t("onboarding.ready_heading")}</h2>
          <p className="mt-1 text-sm">{t("onboarding.ready_description")}</p>
          <Link className={buttonClasses("primary", "md", "mt-3")} to={withRoutePrefix(dashboardPath, prefix)}>
            {t("onboarding.open_dashboard")}
          </Link>
        </Surface>
      ) : null}

      {openModal === "github_token" ? <GithubTokenModal onClose={() => setOpenModal(null)} /> : null}
      {openModal === "configure_agent" ? <ConfigureAgentModal onClose={() => setOpenModal(null)} /> : null}
      {openModal === "add_repository" ? <AddRepositoryModal onClose={() => setOpenModal(null)} /> : null}
      {openModal === "readiness" && repositoryId && readiness.data ? (
        <RepositoryReadinessModal
          onClose={() => setOpenModal(null)}
          open
          repositoryId={repositoryId}
          report={{ ...readiness.data.readiness, execution_probe: readinessProbe.data?.execution_probe ?? readiness.data.readiness.execution_probe }}
        />
      ) : null}
    </main>
  )
}

function profileSlug(key: string) {
  return key.split("@")[0]
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
        ? t("onboarding.agent_ready", {
            provider: setup.credential_status.active_agent_provider_label || providerLabel(setup.credential_status.active_agent_provider)
          })
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
      detail: setup.repository_configured ? t("onboarding.repository_configured", { count: setup.counts.repositories }) : t("onboarding.repository_missing"),
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
      detail: setup.onboarding_chat_started ? t("onboarding.chat_started") : t("onboarding.chat_missing"),
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
