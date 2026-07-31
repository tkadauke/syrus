import { withRoutePrefix } from "../lib/routing"
import { useState } from "react"
import { useMutation, useQueryClient } from "@tanstack/react-query"
import { Link, useLocation, useNavigate } from "react-router-dom"
import type { BootstrapPayload } from "../api/bootstrap"
import { startOnboardingChat } from "../api/chats"
import { updateAdminSettings } from "../api/adminSettings"
import { GithubTokenModal } from "../components/GithubTokenModal"
import { ConfigureAgentModal } from "../components/ConfigureAgentModal"
import { AddRepositoryModal } from "../components/AddRepositoryModal"
import { useT } from "../hooks/useT"

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
  ctaAction?: "start_chat" | "choose_mode"
}

export function OnboardingRoute({ bootstrap }: { bootstrap: BootstrapPayload | null | undefined }) {
  const { t } = useT("common")
  const location = useLocation()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const setup = bootstrap?.setup_status
  const user = bootstrap?.current_user

  if (!user || !setup) {
    return (
      <main aria-label={t("onboarding_aria")} className="mx-auto max-w-5xl p-6">
        <p className="text-sm text-gray-600 dark:text-gray-400">{t('onboarding.loading')}</p>
      </main>
    )
  }

  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [openModal, setOpenModal] = useState<ChecklistStep["ctaModal"] | null>(null)
  const [startingChat, setStartingChat] = useState(false)
  const [chatError, setChatError] = useState<string | null>(null)

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
      setChatError("Could not start the Syrus chat. Try again.")
      setStartingChat(false)
    }
  }

  const chooseMode = useMutation({
    mutationFn: (selectedMode: "advanced" | "simple") =>
      updateAdminSettings({ mode: selectedMode }),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["bootstrap"] })
  })

  const steps = checklistSteps(setup, user, bootstrap?.app.mode_configured ?? false)
  const activeStep = steps.find((step) => !step.complete)
  const complete = !activeStep
  const dashboardPath = bootstrap?.app.mode === "simple" ? "/dashboard/epics" : "/dashboard/jobs?view=list"

  return (
    <main aria-label={t("onboarding_aria")} className="mx-auto max-w-5xl space-y-6 p-6">
      <header className="border-b border-gray-200 dark:border-gray-700 pb-5">
        <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t('onboarding.setup_label')}</p>
        <h1 className="mt-2 text-2xl font-semibold text-gray-900 dark:text-gray-100">{t('onboarding.heading')}</h1>
      </header>

      <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
        <ol className="divide-y divide-gray-200 dark:divide-gray-700">
          {steps.map((step) => {
            const current = activeStep?.key === step.key
            return (
              <li className={checklistItemClass(current)} key={step.key}>
                <div className={checklistContentClass(current)}>
                  <span className={statusMarkerClass(step.complete, current)}>{step.complete ? "OK" : current ? ">" : ""}</span>
                  <div className={current ? "min-w-0 text-center" : "min-w-0"}>
                    <h2 className="text-sm font-medium text-gray-900 dark:text-gray-100">{step.title}</h2>
                    {current ? <p className="mt-2 max-w-xl text-sm text-gray-600 dark:text-gray-400">{step.detail}</p> : null}
                  </div>
                </div>
                {step.complete ? (
                  <span className="self-start rounded bg-green-50 dark:bg-green-950/40 px-2.5 py-1 text-xs font-medium text-green-700 dark:text-green-300 sm:self-center">{t('onboarding.complete_badge')}</span>
                ) : step.ctaAction === "choose_mode" ? (
                  <div className="flex shrink-0 flex-col gap-2 sm:flex-row">
                    <button
                      className={`${primaryCtaClass(current)} sm:min-w-44`}
                      disabled={chooseMode.isPending}
                      onClick={() => chooseMode.mutate("advanced")}
                      type="button"
                    >
                      Yes, I write code
                    </button>
                    <button
                      className={`${primaryCtaClass(false)} sm:min-w-44`}
                      disabled={chooseMode.isPending}
                      onClick={() => chooseMode.mutate("simple")}
                      type="button"
                    >
                      No, build things for me
                    </button>
                  </div>
                ) : step.ctaModal ? (
                  <button className={primaryCtaClass(current)} onClick={() => setOpenModal(step.ctaModal ?? null)} type="button">
                    {step.ctaLabel}
                  </button>
                ) : step.ctaAction === "start_chat" ? (
                  <button className={primaryCtaClass(current)} disabled={startingChat} onClick={launchChat} type="button">
                    {startingChat ? "Opening chat…" : step.ctaLabel}
                  </button>
                ) : (
                  <Link className={primaryCtaClass(current)} to={withRoutePrefix(step.ctaPath, prefix)}>
                    {step.ctaLabel}
                  </Link>
                )}
              </li>
            )
          })}
        </ol>
      </section>

      {chatError ? (
        <p className="rounded border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300" role="alert">{chatError}</p>
      ) : null}

      {complete ? (
        <section className="rounded border border-green-200 dark:border-green-800 bg-green-50 dark:bg-green-950/40 p-4">
          <h2 className="text-sm font-medium text-green-900 dark:text-green-100">{t('onboarding.ready_heading')}</h2>
          <p className="mt-1 text-sm text-green-800 dark:text-green-200">{t('onboarding.ready_description')}</p>
          <Link className="mt-3 inline-flex rounded bg-green-700 px-3 py-2 text-sm font-medium text-white hover:bg-green-800" to={withRoutePrefix(dashboardPath, prefix)}>
            {t('onboarding.open_dashboard')}
          </Link>
        </section>
      ) : null}

      {openModal === "github_token" ? <GithubTokenModal onClose={() => setOpenModal(null)} /> : null}
      {openModal === "configure_agent" ? <ConfigureAgentModal onClose={() => setOpenModal(null)} /> : null}
      {openModal === "add_repository" ? <AddRepositoryModal onClose={() => setOpenModal(null)} /> : null}
    </main>
  )
}

function checklistSteps(setup: SetupStatus, user: NonNullable<BootstrapPayload["current_user"]>, modeConfigured: boolean): ChecklistStep[] {
  return [
    {
      key: "account",
      title: "Account and admin access",
      detail: user.admin ? `${user.display_name} can manage this Syrus instance.` : "Ask an admin to grant access before configuring shared setup.",
      complete: user.admin,
      ctaLabel: "Open account settings",
      ctaPath: "/profile"
    },
    {
      key: "mode",
      title: "How do you work?",
      detail: modeConfigured
        ? "Instance mode is configured."
        : "Tell Syrus how to tailor the experience. Choose based on whether you'll be writing code yourself.",
      complete: modeConfigured,
      ctaLabel: "",
      ctaPath: "",
      ctaAction: "choose_mode"
    },
    {
      key: "github",
      title: "GitHub integration",
      detail: githubStepDetail(setup),
      complete: setup.credential_status.github,
      ctaLabel: "Configure GitHub",
      ctaPath: "/credentials",
      ctaModal: "github_token"
    },
    {
      key: "agent",
      title: "Agent credentials and provider",
      detail: setup.credential_status.agent ? `${providerLabel(setup.credential_status.active_agent_provider)} is ready for runs.` : "Choose a provider and add its credentials.",
      complete: setup.credential_status.agent,
      ctaLabel: "Configure agent",
      ctaPath: "/credentials",
      ctaModal: "configure_agent"
    },
    {
      key: "repository",
      title: "Repository",
      detail: setup.repository_configured ? `${setup.counts.repositories} active repository${setup.counts.repositories === 1 ? "" : "ies"} configured.` : "Add the first repository Syrus should poll or run against.",
      complete: setup.repository_configured,
      ctaLabel: "Add repository",
      ctaPath: "/repositories/new",
      ctaModal: "add_repository"
    },
    {
      key: "chat",
      title: "Meet Syrus",
      detail: setup.onboarding_chat_started
        ? "You've started the Syrus chat. The other tabs are now unlocked."
        : "Start a chat with Syrus. It will explain Epics and Jobs and help you plan your first Epic.",
      complete: setup.onboarding_chat_started,
      ctaLabel: setup.onboarding_chat_started ? "Open Syrus chat" : "Start Syrus chat",
      ctaPath: "/onboarding",
      ctaAction: "start_chat"
    },
    {
      key: "epic",
      title: "Land your first Epic",
      detail: epicStepDetail(setup),
      complete: setup.first_epic_landed,
      ctaLabel: "Open Syrus chat",
      ctaPath: "/onboarding",
      ctaAction: "start_chat"
    }
  ]
}

function epicStepDetail(setup: SetupStatus) {
  if (setup.first_epic_landed) return "Your first Epic landed — Syrus is fully set up."
  if (setup.first_epic_started) return "Your first Epic is in progress. Approve its Jobs so they can land."
  if (setup.first_epic_created) return "Your first Epic is drafted. Move it to In Progress in chat to start it."
  return "In the chat, create your first Epic, move it to In Progress, and approve its Jobs so they land."
}

function githubStepDetail(setup: SetupStatus) {
  const status = setup.credential_status
  if (status.github) return "GitHub token and App are both connected."
  if (status.github_pat) return "Token saved. Register the GitHub App to finish — both are required."
  if (status.github_app) return "GitHub App registered. Add a personal access token to finish — both are required."
  return "Connect a personal access token and the GitHub App — both are required."
}

function providerLabel(provider: SetupStatus["credential_status"]["active_agent_provider"]) {
  return provider === "codex" ? "Codex" : "Claude"
}

function statusMarkerClass(complete: boolean, current: boolean) {
  if (complete) return "mt-0.5 inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-green-600 text-xs font-semibold text-white"
  if (current) return "mt-0.5 inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-blue-600 text-lg leading-none text-white"

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
  return current ? `${base} min-w-48 bg-blue-600 text-white hover:bg-blue-700` : `${base} border border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800`
}
