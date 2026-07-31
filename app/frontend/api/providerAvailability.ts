export type ProviderAvailability = {
  provider: string
  label: string
  model: string | null
  state: "exhausted" | "open" | string
  open: boolean
  usage_exhausted: boolean
  retry_after: string | null
  reason: string | null
  message: string
} | null
