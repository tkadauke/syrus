import { getJson } from "@app/api/client"

export type AdminTailscaleStatus = {
  daemon_running: boolean
  connected: boolean
  hostname: string | null
  tailscale_url: string | null
  auth_key_present: boolean
  net_admin_capable: boolean
}

export function fetchAdminTailscaleStatus() {
  return getJson<AdminTailscaleStatus>("/api/v1/app/admin/tailscale/status")
}
