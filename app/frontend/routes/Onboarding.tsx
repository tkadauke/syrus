import { Link, useLocation } from "react-router-dom"
import type { BootstrapPayload } from "../api/bootstrap"

type SetupStatus = NonNullable<BootstrapPayload["setup_status"]>

type ChecklistStep = {
  key: string
  title: string
  detail: string
  complete: boolean
  ctaLabel: string
  ctaPath: string
}

export function OnboardingRoute({ bootstrap }: { bootstrap: BootstrapPayload | null | undefined }) {
  const location = useLocation()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const setup = bootstrap?.setup_status
  const user = bootstrap?.current_user

  if (!user || !setup) {
    return (
      <main aria-label="Onboarding" className="mx-auto max-w-5xl p-6">
        <p className="text-sm text-gray-600">Loading setup status...</p>
      </main>
    )
  }

  const steps = checklistSteps(setup, user)
  const completedCount = steps.filter((step) => step.complete).length
  const activeStep = steps.find((step) => !step.complete)
  const complete = !activeStep

  return (
    <main aria-label="Onboarding" className="mx-auto max-w-5xl space-y-6 p-6">
      <header className="border-b border-gray-200 pb-5">
        <p className="text-xs font-medium uppercase text-gray-500">First-run setup</p>
        <div className="mt-2 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <h1 className="text-2xl font-semibold text-gray-900">Set up Syrus</h1>
            <p className="mt-2 max-w-2xl text-sm text-gray-600">
              Work through the shortest path to a successful first run.
            </p>
          </div>
          <div className="text-sm text-gray-600">
            <span className="font-medium text-gray-900">{completedCount}</span> of <span>{steps.length}</span> complete
          </div>
        </div>
      </header>

      <section className="rounded border border-gray-200 bg-white">
        <ol className="divide-y divide-gray-200">
          {steps.map((step) => {
            const current = activeStep?.key === step.key
            return (
              <li className="flex flex-col gap-4 p-4 sm:flex-row sm:items-center sm:justify-between" key={step.key}>
                <div className="flex min-w-0 items-start gap-3">
                  <span className={statusMarkerClass(step.complete, current)}>{step.complete ? "OK" : current ? ">" : ""}</span>
                  <div className="min-w-0">
                    <h2 className="text-sm font-medium text-gray-900">{step.title}</h2>
                    <p className="mt-1 text-sm text-gray-600">{step.detail}</p>
                  </div>
                </div>
                {step.complete ? (
                  <span className="self-start rounded bg-green-50 px-2.5 py-1 text-xs font-medium text-green-700 sm:self-center">Complete</span>
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

      {complete ? (
        <section className="rounded border border-green-200 bg-green-50 p-4">
          <h2 className="text-sm font-medium text-green-900">Ready for normal operations</h2>
          <p className="mt-1 text-sm text-green-800">Syrus has completed at least one successful job.</p>
          <Link className="mt-3 inline-flex rounded bg-green-700 px-3 py-2 text-sm font-medium text-white hover:bg-green-800" to={withRoutePrefix("/dashboard/jobs?view=list", prefix)}>
            Open dashboard
          </Link>
        </section>
      ) : null}
    </main>
  )
}

function checklistSteps(setup: SetupStatus, user: NonNullable<BootstrapPayload["current_user"]>): ChecklistStep[] {
  return [
    {
      key: "account",
      title: "Account and admin access",
      detail: user.admin ? `${user.display_name} can manage this Syrus instance.` : "Ask an admin to grant access before configuring shared setup.",
      complete: user.admin,
      ctaLabel: "Open account settings",
      ctaPath: "/settings"
    },
    {
      key: "github",
      title: "GitHub credentials",
      detail: setup.credential_status.github ? "GitHub authentication is available." : "Connect a GitHub token or register the GitHub App.",
      complete: setup.credential_status.github,
      ctaLabel: "Configure GitHub",
      ctaPath: "/credentials/edit"
    },
    {
      key: "agent",
      title: "Agent credentials and provider",
      detail: setup.credential_status.agent ? `${providerLabel(setup.credential_status.active_agent_provider)} is ready for runs.` : "Choose a provider and add its credentials.",
      complete: setup.credential_status.agent,
      ctaLabel: "Configure agent",
      ctaPath: "/credentials/edit"
    },
    {
      key: "repository",
      title: "Repository",
      detail: setup.repository_configured ? `${setup.counts.repositories} active repository${setup.counts.repositories === 1 ? "" : "ies"} configured.` : "Add the first repository Syrus should poll or run against.",
      complete: setup.repository_configured,
      ctaLabel: "Add repository",
      ctaPath: "/repositories/new"
    },
    {
      key: "first_job",
      title: "First issue or direct job",
      detail: setup.first_job_started ? "The first job has been created." : "Create a direct job or delegate a GitHub issue to start the first run.",
      complete: setup.first_job_started,
      ctaLabel: "Start direct job",
      ctaPath: "/jobs/new"
    },
    {
      key: "watch_job",
      title: "Watch first job",
      detail: setup.first_successful_job_completed ? "At least one job closed successfully." : "Track the first run until it closes successfully.",
      complete: setup.first_successful_job_completed,
      ctaLabel: "Watch jobs",
      ctaPath: "/dashboard/jobs?view=list"
    }
  ]
}

function providerLabel(provider: SetupStatus["credential_status"]["active_agent_provider"]) {
  return provider === "codex" ? "Codex" : "Claude"
}

function statusMarkerClass(complete: boolean, current: boolean) {
  if (complete) return "mt-0.5 inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-green-600 text-xs font-semibold text-white"
  if (current) return "mt-0.5 inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-blue-600 text-lg leading-none text-white"

  return "mt-0.5 inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-full border border-gray-300 bg-white"
}

function primaryCtaClass(current: boolean) {
  const base = "inline-flex shrink-0 justify-center rounded px-3 py-2 text-sm font-medium"
  return current ? `${base} bg-blue-600 text-white hover:bg-blue-700` : `${base} border border-gray-300 text-gray-700 hover:bg-gray-50`
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  return `${prefix}${path.startsWith("/") ? path : `/${path}`}`
}
