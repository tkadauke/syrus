import { getJson } from "@app/api/client"

export type CoverageTrendPoint = {
  date: string
  lines_pct: number | null
  branches_pct: number | null
  functions_pct: number | null
  branch: string
}

export type CoverageTrendPayload = {
  repository_id: number
  days: number
  points: CoverageTrendPoint[]
}

export function fetchRepositoryCoverageTrend(id: number | string, days = 30) {
  return getJson<CoverageTrendPayload>(`/api/v1/app/repositories/${id}/coverage_trend?days=${days}`)
}
