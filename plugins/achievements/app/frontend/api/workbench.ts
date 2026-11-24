import { getJson } from "@app/api/client"
import type { AchievementPresentation, AchievementScope } from "./achievements"

export type ImplementationStatus = "implemented" | "partial" | "planned"

export type WorkbenchDefinition = {
  key: string
  version: number
  scope: AchievementScope
  trigger: string
  evaluator: string
  subject_kinds: string[]
  visibility: "visible" | "hidden"
  category: string
  rarity: string
  presentation: AchievementPresentation
  implementation_status: ImplementationStatus
}

export type WorkbenchCatalog = {
  definitions: WorkbenchDefinition[]
  problems: string[]
  vocabulary: {
    scope: string[]
    category: string[]
    rarity: string[]
    visibility: string[]
    implementation_status: string[]
    trigger: string[]
  }
}

export const workbenchQueryKey = ["achievements", "workbench"] as const

export function fetchWorkbenchCatalog() {
  return getJson<WorkbenchCatalog>("/api/v1/app/admin/achievements/workbench")
}
