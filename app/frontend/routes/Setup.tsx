import { useQuery } from "@tanstack/react-query"
import { Link, useLocation } from "react-router-dom"
import { fetchSetupStatus, type SetupStatusPayload, type SetupStepKey } from "../api/setup"

export function SetupRoute() {
  const location = useLocation()
  const setup = useQuery({
    queryKey: ["setup"],
    queryFn: fetchSetupStatus
  })
  const prefix = routePrefix(location.pathname)

  if (setup.isPending) return <main aria-label="First-run setup" className="p-6 text-sm text-gray-600">Loading setup...</main>
  if (setup.isError) return <main aria-label="First-run setup" className="p-6 text-sm text-red-700">Unable to load setup status.</main>

  return <SetupView payload={setup.data} prefix={prefix} />
}

function SetupView({ payload, prefix }: { payload: SetupStatusPayload; prefix: string }) {
  const action = primaryAction(payload)

  return (
    <main aria-label="First-run setup" className="mx-auto max-w-5xl space-y-6 p-6">
      <header className="flex flex-wrap items-start justify-between gap-4 border-b border-gray-200 pb-5">
        <div>
          <p className="text-sm font-medium text-blue-700">First-run setup</p>
          <h1 className="mt-1 text-3xl font-semibold text-gray-900">Get to the first successful Job</h1>
          <p className="mt-2 max-w-2xl text-sm text-gray-600">Complete the minimum path from credentials to a watched Job or PR.</p>
        </div>
        <div className="rounded border border-gray-200 bg-white px-4 py-3 text-sm">
          <div className="font-medium text-gray-900">{payload.progress.completed} of {payload.progress.total} complete</div>
          <div className="mt-1 h-2 w-44 overflow-hidden rounded bg-gray-100">
            <div className="h-full bg-blue-600" style={{ width: `${(payload.progress.completed / payload.progress.total) * 100}%` }} />
          </div>
        </div>
      </header>

      <section className="grid gap-4 md:grid-cols-[minmax(0,1fr)_18rem]">
        <div className="overflow-hidden rounded border border-gray-200 bg-white">
          {payload.progress.steps.map((step) => (
            <SetupStep key={step.key} payload={payload} prefix={prefix} step={step} />
          ))}
        </div>

        <aside className="space-y-4">
          <div className="rounded border border-gray-200 bg-white p-4">
            <h2 className="text-sm font-semibold text-gray-900">Credential mode</h2>
            <p className="mt-2 text-sm text-gray-600">{payload.github_app.explanation}</p>
            {payload.github_app.register_path ? <Link className="mt-3 inline-flex text-sm font-medium text-blue-700 hover:text-blue-900" to={withRoutePrefix(payload.github_app.register_path, prefix)}>Register GitHub App</Link> : null}
            {payload.github_app.installations_path ? <Link className="mt-3 block text-sm font-medium text-blue-700 hover:text-blue-900" to={withRoutePrefix(payload.github_app.installations_path, prefix)}>Review installations</Link> : null}
          </div>

          <div className="rounded border border-gray-200 bg-white p-4">
            <h2 className="text-sm font-semibold text-gray-900">System readiness</h2>
            <dl className="mt-3 space-y-2 text-sm text-gray-600">
              <div className="flex justify-between gap-3"><dt>Runs</dt><dd className={payload.system.runs_paused ? "text-red-700" : "text-green-700"}>{payload.system.runs_paused ? "paused" : "enabled"}</dd></div>
              <div className="flex justify-between gap-3"><dt>Polling</dt><dd className={payload.system.polling_paused ? "text-red-700" : "text-green-700"}>{payload.system.polling_paused ? "paused" : "enabled"}</dd></div>
              <div className="flex justify-between gap-3"><dt>Data root</dt><dd className="truncate font-mono" title={payload.system.data_root}>{payload.system.data_root}</dd></div>
              <div className="flex justify-between gap-3"><dt>Revision</dt><dd className="truncate font-mono">{payload.system.revision}</dd></div>
            </dl>
          </div>

          <div className="rounded border border-gray-200 bg-white p-4">
            <h2 className="text-sm font-semibold text-gray-900">Next action</h2>
            <p className="mt-2 text-sm text-gray-600">{action.description}</p>
            <Link className="mt-3 inline-flex rounded bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-500" to={withRoutePrefix(action.path, prefix)}>{action.label}</Link>
          </div>
        </aside>
      </section>
    </main>
  )
}

function SetupStep({ payload, prefix, step }: {
  payload: SetupStatusPayload
  prefix: string
  step: { key: SetupStepKey; label: string; complete: boolean }
}) {
  return (
    <div className="grid gap-3 border-b border-gray-100 p-4 last:border-b-0 sm:grid-cols-[10rem_minmax(0,1fr)_auto] sm:items-center">
      <div className="flex items-center gap-2">
        <span className={`inline-flex h-5 w-5 items-center justify-center rounded-full text-[10px] font-semibold ${step.complete ? "bg-green-100 text-green-700" : "bg-gray-100 text-gray-500"}`}>{step.complete ? "OK" : ""}</span>
        <h2 className="text-sm font-semibold text-gray-900">{step.label}</h2>
      </div>
      <p className="text-sm text-gray-600">{stepDescription(payload, step.key)}</p>
      <StepAction payload={payload} prefix={prefix} stepKey={step.key} />
    </div>
  )
}

function StepAction({ payload, prefix, stepKey }: { payload: SetupStatusPayload; prefix: string; stepKey: SetupStepKey }) {
  const action = actionForStep(payload, stepKey)
  if (!action) return null

  return <Link className="text-sm font-medium text-blue-700 hover:text-blue-900" to={withRoutePrefix(action.path, prefix)}>{action.label}</Link>
}

function primaryAction(payload: SetupStatusPayload) {
  if (payload.next_step === "complete") {
    return { label: "Open dashboard", path: payload.paths.dashboard_jobs_path, description: "Setup is complete. The dashboard is now the working surface." }
  }

  return actionForStep(payload, payload.next_step) || {
    label: "Open dashboard",
    path: payload.paths.dashboard_jobs_path,
    description: "Watch the current Job until it succeeds, opens a PR, or shows a failure to diagnose."
  }
}

function actionForStep(payload: SetupStatusPayload, key: SetupStepKey) {
  if (key === "credentials") return { label: "Open credentials", path: payload.paths.credentials_path, description: "Add a GitHub PAT and credentials for the selected agent provider." }
  if (key === "repository") return { label: "Add repository", path: payload.paths.new_repository_path, description: "Register the first repository Syrus should poll." }
  if (key === "first_job") return { label: "Create direct Job", path: payload.paths.new_job_path, description: "Create a direct Job, or label a GitHub issue from the repository issues tab." }
  if (key === "watch_job" && payload.first_job.job) return { label: "Watch Job", path: payload.first_job.job.job_path, description: "Watch the current Job until it succeeds, opens a PR, or shows a failure to diagnose." }
  return null
}

function stepDescription(payload: SetupStatusPayload, key: SetupStepKey) {
  if (key === "credentials") {
    const github = payload.credentials.github_token ? "GitHub PAT saved" : "GitHub PAT missing"
    const agent = payload.credentials.selected_agent_provider_configured ? `${titleize(payload.credentials.selected_agent_provider)} ready` : `${titleize(payload.credentials.selected_agent_provider)} credentials missing`
    return `${github}; ${agent}.`
  }
  if (key === "repository") {
    if (payload.repositories.first) return `${payload.repositories.first.slug} uses ${payload.repositories.first.credential_mode === "app" ? "the GitHub App" : "PAT fallback"}.`
    return "Add an active repository with a default branch and trigger label."
  }
  if (key === "first_job") {
    if (payload.first_job.job) return `${payload.first_job.job.title} is ${payload.first_job.job.state}.`
    return payload.repositories.first ? `Create a direct Job or label an issue with ${payload.repositories.first.trigger_label}.` : "Create the first Job after a repository exists."
  }
  if (payload.first_job.successful) return "A successful Job or PR exists."
  return "Keep the first Job page open while Syrus runs prepare, implement, summarize, and push."
}

function titleize(value: string) {
  return value.replace(/\b\w/g, (letter) => letter.toUpperCase())
}

function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  return `${prefix}${path.startsWith("/") ? path : `/${path}`}`
}
