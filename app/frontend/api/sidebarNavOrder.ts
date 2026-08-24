import { patchJson } from "./client"

export function updateSidebarNavOrder(order: string[]) {
  return patchJson<{ sidebar_nav_order: string[] }>("/api/v1/app/sidebar_nav_order", { order })
}
