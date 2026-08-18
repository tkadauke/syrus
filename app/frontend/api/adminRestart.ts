import { postJson } from "./client"

export type RestartComponent = "web" | "worker" | "all"

export type RestartResult = {
  initiated: boolean
  component: RestartComponent
  active_runs: number
  message?: string
}

export function requestRestart(component: RestartComponent, force = false) {
  return postJson<RestartResult>("/api/v1/app/admin/restart", { component, force })
}
