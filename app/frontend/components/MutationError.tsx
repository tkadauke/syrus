import { ApiError } from "../api/client"

export function MutationError({ error, fallback }: { error: unknown; fallback: string }) {
  const message = error instanceof ApiError ? error.message : fallback
  return (
    <p className="mt-2 text-xs text-danger" role="alert">
      {message}
    </p>
  )
}
