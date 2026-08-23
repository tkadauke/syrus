import { getJson, patchJson } from "./client"

export type AdminFeature = {
  slug: string
  category: string
  name: string
  description: string | null
  enabled: boolean
  name_i18n_key?: string | null
  description_i18n_key?: string | null
}

export type AdminFeatureCategory = {
  category: string
  features: AdminFeature[]
}

export type AdminFeaturesPayload = {
  categories: AdminFeatureCategory[]
  work_unit_ownership?: AdminWorkUnitOwnershipGate[]
}

export type AdminWorkUnitOwnershipGate = {
  gate: string
  enabled: boolean
  paths: AdminWorkUnitOwnershipPath[]
}

export type AdminWorkUnitOwnershipPath = {
  path: string
  owner: "legacy" | "work_unit"
  gate: string
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
