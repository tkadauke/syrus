import { withRoutePrefix } from "../lib/routing"
import { useQuery } from "@tanstack/react-query"
import { useTranslation } from "react-i18next"
import { Link } from "react-router-dom"
import { fetchBootstrap, readInitialBootstrap, type BootstrapPayload } from "../api/bootstrap"
import { useBackendOutage } from "../hooks/useBackendUpdate"
import { buttonClasses } from "./Button"

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
  // While the desktop shell's backend update has the containers down,
  // setup_status reflects failed checks, not reality — falling back to the
  // generic empty-state copy avoids telling the user to "connect credentials"
  // they already have. (During the image pull the old backend still serves,
  // so outage stays false and the setup CTA renders normally.)
  const backendOutage = useBackendOutage()
  const nextStep = backendOutage ? null : setupStatus?.next_step || null

  const setupCopy: Record<NonNullable<SetupStatus["next_step"]>, { title: string; description: string; action: string; latin: string }> = {
    configure_credentials: {
      title: t("nav:onboarding.configure_credentials_title"),
      description: t("nav:onboarding.configure_credentials_description"),
      action: t("nav:onboarding.configure_credentials_action"),
      latin: "Tesseram da"
    },
    add_repository: {
      title: t("nav:onboarding.add_repository_title"),
      description: t("nav:onboarding.add_repository_description"),
      action: t("nav:onboarding.add_repository_action"),
      latin: "Horrea aperi"
    },
    start_first_chat: {
      title: t("nav:onboarding.start_first_chat_title"),
      description: t("nav:onboarding.start_first_chat_description"),
      action: t("nav:onboarding.start_first_chat_action"),
      latin: "Syrum conveni"
    }
  }

  const copy = nextStep ? setupCopy[nextStep] : null
  const actionPath = (backendOutage ? null : setupStatus?.next_step_path) || fallbackActionPath || null
  const actionText = copy?.action || fallbackActionText

  return (
    <section className="rounded border border-dashed border-gray-300 bg-white p-6 text-sm text-gray-600">
      <div className="max-w-2xl space-y-3">
        <div>
          <h2 className="text-base font-semibold text-gray-900">{copy?.title || fallbackTitle}</h2>
          {copy?.latin ? <p className="text-xs italic text-gray-400">{copy.latin}</p> : null}
          <p className="mt-1 leading-6">{copy?.description || fallbackDescription}</p>
        </div>
        {actionPath && actionText && /^https?:\/\//.test(actionPath) ? (
          <a className={buttonClasses("primary")} href={actionPath} rel="noopener" target="_blank">
            {actionText}
          </a>
        ) : actionPath && actionText ? (
          <Link className={buttonClasses("primary")} to={withRoutePrefix(actionPath, prefix)}>
            {actionText}
          </Link>
        ) : null}
      </div>
    </section>
  )
}

