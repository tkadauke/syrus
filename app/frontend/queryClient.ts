import { QueryClient, type QueryClientConfig } from "@tanstack/react-query"

export const queryClientConfig = {
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      refetchOnWindowFocus: false,
      retry: 1
    }
  }
} satisfies QueryClientConfig

export function createQueryClient() {
  return new QueryClient(queryClientConfig)
}
