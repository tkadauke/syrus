import { useQuery } from "@tanstack/react-query"
import { Link } from "react-router-dom"
import { fetchBootstrap, type BootstrapPayload } from "../api/bootstrap"

type SetupStatus = NonNullable<BootstrapPayload["setup_status"]>

type OnboardingEmptyStateProps = {
  fallbackActionPath?: string
  fallbackActionText?: string
  fallbackDescription: string
  fallbackTitle: string
  prefix: string
  setupStatus?: SetupStatus | null
}

const setupCopy: Record<NonNullable<SetupStatus["next_step"]>, { title: string; description: string; action: string }> = {
  configure_credentials: {
    title: "Connect credentials first",
    description: "Syrus needs both GitHub access and an agent provider before it can poll repositories or run jobs.",
    action: "Open credentials"
  },
  add_repository: {
    title: "Add your first repository",
    description: "Credentials are ready. Add a repository so Syrus knows where to watch issues and where direct jobs can run.",
    action: "Add repository"
  },
  start_first_job: {
    title: "Start the first job",
    description: "Credentials and a repository are ready. Create a direct job or label a GitHub issue to send work through the pipeline.",
    action: "Create direct job"
  },
  watch_first_job: {
    title: "Watch the first job",
    description: "The first job has started. Follow it until Syrus opens a PR or records a successful no-change result.",
    action: "Open dashboard"
  }
}

export function useSetupStatus() {
  const bootstrap = useQuery({
    queryKey: ["bootstrap"],
    queryFn: fetchBootstrap,
    enabled: false
  })
  return bootstrap.data?.setup_status ?? null
}

export function OnboardingEmptyState({
  fallbackActionPath,
  fallbackActionText,
  fallbackDescription,
  fallbackTitle,
  prefix,
  setupStatus
}: OnboardingEmptyStateProps) {
  const nextStep = setupStatus?.next_step || null
  const copy = nextStep ? setupCopy[nextStep] : null
  const actionPath = setupStatus?.next_step_path || fallbackActionPath || null
  const actionText = copy?.action || fallbackActionText

  return (
    <section className="rounded border border-dashed border-gray-300 bg-white p-6 text-sm text-gray-600">
      <div className="max-w-2xl space-y-3">
        <div>
          <h2 className="text-base font-semibold text-gray-900">{copy?.title || fallbackTitle}</h2>
          <p className="mt-1 leading-6">{copy?.description || fallbackDescription}</p>
        </div>
        {actionPath && actionText && /^https?:\/\//.test(actionPath) ? (
          <a className="inline-flex rounded bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-500" href={actionPath} rel="noopener" target="_blank">
            {actionText}
          </a>
        ) : actionPath && actionText ? (
          <Link className="inline-flex rounded bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-500" to={withRoutePrefix(actionPath, prefix)}>
            {actionText}
          </Link>
        ) : null}
      </div>
    </section>
  )
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}
