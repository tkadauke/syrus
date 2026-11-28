import { getJson, patchJson } from "./client"

export type EnvironmentPolicyPayload = {
  policy: Record<string, unknown>
  registry: { configured: boolean; url?: string; repository_prefix?: string; secure?: boolean; roles?: Record<string, boolean>; error?: string }
  network_rules_path: string
  message?: string
}

export const fetchEnvironmentPolicy = () => getJson<EnvironmentPolicyPayload>("/api/v1/app/admin/environment_policy")
export const updateEnvironmentPolicy = (policy: Record<string, unknown>) =>
  patchJson<EnvironmentPolicyPayload>("/api/v1/app/admin/environment_policy", { environment_policy: policy })
