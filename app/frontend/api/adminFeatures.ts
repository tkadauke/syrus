import { getJson, patchJson } from "./client"

export type AdminFeature = {
  slug: string
  category: string
  name: string
  description: string | null
  enabled: boolean
}

export type AdminFeatureCategory = {
  category: string
  features: AdminFeature[]
}

export type AdminFeaturesPayload = {
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
