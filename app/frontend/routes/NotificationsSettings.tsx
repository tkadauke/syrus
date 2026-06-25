import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useState, type ReactNode } from "react"
import { ApiError } from "../api/client"
import {
  fetchNotificationPreferences,
  updateNotificationPreferences,
  type NotificationPreferenceKind,
  type NotificationPreferencesPayload
} from "../api/notifications"
import { NoticeToast } from "../components/NoticeToast"

const queryKey = ["notification_preferences"] as const

const notificationPreferenceLabels: Array<{ kind: NotificationPreferenceKind; label: string }> = [
  { kind: "job_failed", label: "Notify me when a job fails" },
  { kind: "job_implemented", label: "Notify me when a PR is ready for review" },
  { kind: "pr_comment_addressed", label: "Notify me when Syrus addresses my PR comments" },
  { kind: "pr_merged", label: "Notify me when a job is merged" },
  { kind: "epic_completed", label: "Notify me when an epic completes" }
]

export function NotificationsSettingsRoute() {
  const [notice, setNotice] = useState<string | null>(null)

  return (
    <main aria-label="Notification settings" className="mx-auto max-w-4xl space-y-6 p-6">
      <header>
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">Notifications</h1>
        <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">Choose which Syrus events create notifications for your account.</p>
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      <NotificationPreferencesPanel onNotice={setNotice} />
    </main>
  )
}

function NotificationPreferencesPanel({ onNotice }: { onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const preferences = useQuery({
    queryKey,
    queryFn: fetchNotificationPreferences
  })
  const update = useMutation({
    mutationFn: ({ kind, enabled }: { kind: NotificationPreferenceKind; enabled: boolean }) => updateNotificationPreferences({ [kind]: enabled }),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || "Notification preferences updated.")
    }
  })

  return (
    <section className="rounded border border-gray-200 bg-white p-5 dark:border-gray-700 dark:bg-gray-900">
      {preferences.isPending ? <p className="text-sm text-gray-500 dark:text-gray-400">Loading notification preferences...</p> : null}
      {preferences.isError ? <PanelMessage tone="error">{errorMessage(preferences.error, "Unable to load notification preferences.")}</PanelMessage> : null}
      {update.isError ? <PanelMessage tone="error">{errorMessage(update.error, "Unable to update notification preferences.")}</PanelMessage> : null}
      {preferences.isSuccess ? (
        <NotificationPreferenceToggles
          disabled={update.isPending}
          onChange={(kind, enabled) => {
            onNotice(null)
            queryClient.setQueryData<NotificationPreferencesPayload>(queryKey, {
              ...preferences.data,
              notification_preferences: {
                ...preferences.data.notification_preferences,
                [kind]: enabled
              }
            })
            update.mutate({ kind, enabled })
          }}
          payload={preferences.data}
        />
      ) : null}
    </section>
  )
}

function NotificationPreferenceToggles({
  payload,
  disabled,
  onChange
}: {
  payload: NotificationPreferencesPayload
  disabled: boolean
  onChange: (kind: NotificationPreferenceKind, enabled: boolean) => void
}) {
  return (
    <div className="space-y-3">
      {notificationPreferenceLabels.map(({ kind, label }) => (
        <label className="flex items-center justify-between gap-4 rounded border border-gray-200 px-3 py-2 text-sm dark:border-gray-700" key={kind}>
          <span className="font-medium text-gray-700 dark:text-gray-300">{label}</span>
          <input
            aria-label={label}
            checked={payload.notification_preferences[kind]}
            className="h-4 w-4 rounded border-gray-400"
            disabled={disabled}
            onChange={(event) => onChange(kind, event.target.checked)}
            type="checkbox"
          />
        </label>
      ))}
    </div>
  )
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  const colors = {
    error: "border-red-200 bg-red-50 text-red-700 dark:border-red-800 dark:bg-red-950/40 dark:text-red-300",
    muted: "border-gray-200 bg-white text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-400"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}
