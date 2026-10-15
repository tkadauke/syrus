import type { QueryClient } from "@tanstack/react-query"

export function invalidateJobSurfaces(queryClient: QueryClient, jobId: string | number) {
  void queryClient.invalidateQueries({ queryKey: ["dashboard"] })
  void queryClient.invalidateQueries({ queryKey: ["jobs", String(jobId)], exact: true })
}
