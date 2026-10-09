import { getJson, patchJson } from "./client"

export type AdminFeature = {
  slug: string
  category: string
  name: string
  description: string | null
  experimental: boolean
  enabled: boolean
  name_i18n_key?: string | null
  description_i18n_key?: string | null
}

export type AdminFeatureCategory = {
  category: string
  features: AdminFeature[]
}

export type AdminFeaturesPayload = {
  beta_mode_enabled?: boolean
  categories: AdminFeatureCategory[]
}

export type AdminFeaturePayload = {
  feature: AdminFeature
}

export function fetchAdminFeatures() {
  return getJson<AdminFeaturesPayload>("/api/v1/app/admin/features")
}

export function updateAdminFeature(slug: string, enabled: boolean) {
  return patchJson<AdminFeaturePayload>(`/api/v1/app/admin/features/${encodeURIComponent(slug)}`, {
    feature: { enabled }
  })
}

export function enableBetaModeForInstance() {
  return patchJson<unknown>("/api/v1/app/admin/settings", {
    app_setting: { beta_mode_enabled: true }
  })
}
