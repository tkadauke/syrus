import type { QueryClient } from "@tanstack/react-query"
import { fetchSidebarPluginPages, sidebarPluginPagesQueryKey } from "../api/sidebarPages"

export async function refreshSidebarPluginPages(queryClient: QueryClient) {
  await queryClient.invalidateQueries({ queryKey: sidebarPluginPagesQueryKey })

  try {
    await queryClient.fetchQuery({
      queryKey: sidebarPluginPagesQueryKey,
      queryFn: fetchSidebarPluginPages,
      staleTime: 0
    })
  } catch (_error) {
    // The invalidation is enough for eventual recovery; plugin detail
    // navigation should still work when this best-effort refresh fails.
  }
}
