// Shared formatting helpers (previously copied across routes).

// Human-readable byte size (B / KB / MB). Returns "unknown size" for a
// null/undefined value; 0 renders as "0 B". AdminOverview keeps its own
// TB/GB-capable variant.
export function formatBytes(value: number | null | undefined): string {
  if (value == null) return "unknown size"
  if (value < 1024) return `${value} B`
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`
  return `${(value / (1024 * 1024)).toFixed(1)} MB`
}

// USD cost defaults to 4 decimal places because agent costs are frequently
// fractions of a cent. Summary views can opt into fewer digits.
export function formatCurrency(value: number, fractionDigits = 4): string {
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    minimumFractionDigits: fractionDigits,
    maximumFractionDigits: fractionDigits
  }).format(value)
}
