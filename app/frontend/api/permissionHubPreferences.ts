import { patchJson } from "./client"

export type PermissionHubMode = "simple" | "advanced"

export function updatePermissionHubPreferences(mode: PermissionHubMode) {
  return patchJson<{ mode: PermissionHubMode }>("/api/v1/app/permission_hub_preferences", {
    permission_hub_preferences: { mode }
  })
}
