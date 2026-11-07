import { patchJson } from "./client"

export function reportBrowserTimeZone(timeZone: string) {
  return patchJson<{ time_zone: string; mode: "automatic" | "manual" }>("/api/v1/app/user_time_zone", {
    time_zone: timeZone
  })
}
