import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { ReactNode } from "react"
import {
  fetchAdminFeatures,
  updateAdminFeature,
  type AdminFeature,
  type AdminFeaturesPayload
} from "../api/adminFeatures"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { errorMessage } from "../lib/errorMessage"

const queryKey = ["admin", "features"] as const

export function AdminFeatures() {
  const { t } = useT("admin")
  usePageTitle(t("page_title_features"))
  const features = useQuery({
    queryKey,
    queryFn: fetchAdminFeatures
  })

  return (
    <main aria-label={t("aria_features")} className="mx-auto max-w-6xl space-y-6 p-6">
      <header className="border-b border-gray-200 pb-4 dark:border-gray-700">
        <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("section_label")}</p>
        <h1 className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("features.heading")}</h1>
      </header>

      {features.isPending ? <PanelMessage>{t("features.loading")}</PanelMessage> : null}
      {features.isError ? <PanelMessage tone="error">{errorMessage(features.error, t("features.error_load"))}</PanelMessage> : null}
      {features.isSuccess ? <FeaturesView payload={features.data} /> : null}
    </main>
  )
}

function FeaturesView({ payload }: { payload: AdminFeaturesPayload }) {
  const { t } = useT("admin")
  if (payload.categories.length === 0) {
    return (
      <section className="rounded border border-dashed border-gray-300 bg-white p-8 text-center dark:border-gray-700 dark:bg-gray-900">
        <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100">{t("features.no_features_heading")}</h2>
        <p className="mt-2 text-sm text-gray-600 dark:text-gray-300">{t("features.no_features_body")}</p>
      </section>
    )
  }

  return (
    <div className="space-y-8">
      {payload.categories.map((category) => (
        <section aria-label={category.category} className="space-y-3" key={category.category}>
          <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100">{category.category}</h2>
          <div className="grid gap-3 md:grid-cols-2">
            {category.features.map((feature) => <FeatureCard feature={feature} key={feature.slug} />)}
          </div>
        </section>
      ))}
    </div>
  )
}

function FeatureCard({ feature }: { feature: AdminFeature }) {
  const { t } = useT("admin")
  const queryClient = useQueryClient()
  const toggleFeature = useMutation({
    mutationFn: (enabled: boolean) => updateAdminFeature(feature.slug, enabled),
    onMutate: async (enabled) => {
      await queryClient.cancelQueries({ queryKey })
      const previous = queryClient.getQueryData<AdminFeaturesPayload>(queryKey)
      queryClient.setQueryData<AdminFeaturesPayload>(queryKey, (current) => updateCachedFeature(current, feature.slug, enabled))
      return { previous }
    },
    onError: (_error, _enabled, context) => {
      queryClient.setQueryData(queryKey, context?.previous)
    },
    onSuccess: (payload) => {
      queryClient.setQueryData<AdminFeaturesPayload>(queryKey, (current) => updateCachedFeature(current, payload.feature.slug, payload.feature.enabled))
    },
    onSettled: () => {
      void queryClient.invalidateQueries({ queryKey })
    }
  })

  return (
    <article className="rounded border border-gray-200 bg-white p-4 shadow-sm dark:border-gray-700 dark:bg-gray-900">
      <div className="flex items-start justify-between gap-4">
        <div className="min-w-0">
          <h3 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{feature.name}</h3>
          <p className="mt-1 break-all font-mono text-xs text-gray-500 dark:text-gray-400">{feature.slug}</p>
        </div>
        <label className="inline-flex shrink-0 items-center gap-2 text-sm font-medium text-gray-700 dark:text-gray-200">
          <span>{feature.enabled ? t("features.enabled") : t("features.disabled")}</span>
          <input
            checked={feature.enabled}
            className="sr-only peer"
            disabled={toggleFeature.isPending}
            onChange={(event) => toggleFeature.mutate(event.target.checked)}
            type="checkbox"
          />
          <span className="h-6 w-11 rounded-full bg-gray-300 after:mt-0.5 after:ml-0.5 after:block after:h-5 after:w-5 after:rounded-full after:bg-white after:transition peer-checked:bg-blue-600 peer-checked:after:translate-x-5 peer-focus-visible:outline peer-focus-visible:outline-2 peer-focus-visible:outline-offset-2 peer-focus-visible:outline-blue-600 peer-disabled:opacity-60 dark:bg-gray-700 dark:peer-checked:bg-blue-500" />
        </label>
      </div>
      {feature.description ? <p className="mt-3 text-sm leading-6 text-gray-600 dark:text-gray-300">{feature.description}</p> : null}
      {toggleFeature.isError ? <p className="mt-3 text-sm text-red-700 dark:text-red-300" role="alert">{errorMessage(toggleFeature.error, t("features.error_update"))}</p> : null}
    </article>
  )
}

function updateCachedFeature(payload: AdminFeaturesPayload | undefined, slug: string, enabled: boolean) {
  if (!payload) return payload

  return {
    ...payload,
    categories: payload.categories.map((category) => ({
      ...category,
      features: category.features.map((feature) => feature.slug === slug ? { ...feature, enabled } : feature)
    }))
  }
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`p-4 text-sm ${tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-600 dark:text-gray-300"}`}>{children}</div>
}

