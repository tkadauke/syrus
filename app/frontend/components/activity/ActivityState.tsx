import { useT } from "../../hooks/useT"

/** Loading / empty / error treatment shared by every Activity tab. */
export function ActivityState({ kind, message }: { kind: "loading" | "empty" | "error"; message?: string }) {
  const { t } = useT("nav")
  const text = message ?? t(`activity.${kind}`)
  return (
    <p
      className={`px-4 py-8 text-center text-sm ${kind === "error" ? "text-danger" : "text-text-muted"}`}
      data-activity-state={kind}
      role={kind === "error" ? "alert" : "status"}
    >
      {text}
    </p>
  )
}
