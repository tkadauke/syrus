import { useQuery } from "@tanstack/react-query"
import { useTranslation } from "react-i18next"
import { Link } from "react-router-dom"
import { fetchBootstrap, readInitialBootstrap, type BootstrapPayload } from "../api/bootstrap"

type SetupStatus = NonNullable<BootstrapPayload["setup_status"]>

type OnboardingEmptyStateProps = {
  fallbackActionPath?: string
  fallbackActionText?: string
  fallbackDescription: string
  fallbackTitle: string
  prefix: string
  setupStatus?: SetupStatus | null
}

export function useSetupStatus() {
  const initialBootstrap = readInitialBootstrap()
  const bootstrap = useQuery({
    queryKey: ["bootstrap"],
    queryFn: fetchBootstrap,
    enabled: false,
    initialData: initialBootstrap ?? undefined,
    staleTime: initialBootstrap ? Number.POSITIVE_INFINITY : 0
  })
  return bootstrap.data?.setup_status ?? initialBootstrap?.setup_status ?? null
}

export function OnboardingEmptyState({
  fallbackActionPath,
  fallbackActionText,
  fallbackDescription,
  fallbackTitle,
  prefix,
  setupStatus
}: OnboardingEmptyStateProps) {
  const { t } = useTranslation("nav")
  const nextStep = setupStatus?.next_step || null

  const setupCopy: Record<NonNullable<SetupStatus["next_step"]>, { title: string; description: string; action: string }> = {
    configure_credentials: {
      title: t("nav:onboarding.configure_credentials_title"),
      description: t("nav:onboarding.configure_credentials_description"),
      action: t("nav:onboarding.configure_credentials_action")
    },
    add_repository: {
      title: t("nav:onboarding.add_repository_title"),
      description: t("nav:onboarding.add_repository_description"),
      action: t("nav:onboarding.add_repository_action")
    },
    start_first_chat: {
      title: t("nav:onboarding.start_first_chat_title"),
      description: t("nav:onboarding.start_first_chat_description"),
      action: t("nav:onboarding.start_first_chat_action")
    }
  }

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
