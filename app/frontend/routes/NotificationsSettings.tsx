import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useState } from "react"
import {
  fetchNotificationPreferences,
  updateNotificationPreferences,
  type NotificationPreferenceKind,
  type NotificationPreferencesPayload
} from "../api/notifications"
import { NoticeToast } from "../components/NoticeToast"
import { PanelMessage } from "../components/PanelMessage"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { errorMessage } from "../lib/errorMessage"

const queryKey = ["notification_preferences"] as const

const notificationPreferenceKinds: Array<{ kind: NotificationPreferenceKind; labelKey: string }> = [
  { kind: "job_failed", labelKey: "notifications.pref_job_failed" },
  { kind: "job_implemented", labelKey: "notifications.pref_job_implemented" },
  { kind: "pr_comment_addressed", labelKey: "notifications.pref_pr_comment_addressed" },
  { kind: "pr_merged", labelKey: "notifications.pref_pr_merged" },
  { kind: "epic_completed", labelKey: "notifications.pref_epic_completed" },
  { kind: "epic_review_ready", labelKey: "notifications.pref_epic_review_ready" },
  { kind: "epic_failed", labelKey: "notifications.pref_epic_failed" },
  { kind: "epic_feedback_queued", labelKey: "notifications.pref_epic_feedback_queued" },
  { kind: "main_inconclusive", labelKey: "notifications.pref_main_inconclusive" }
]

const desktopNotificationPreferenceKinds: Array<{ kind: NotificationPreferenceKind; labelKey: string; descKey: string }> = [
  {
    kind: "desktop_job_implemented",
    labelKey: "notifications.desktop_job_implemented_label",
    descKey: "notifications.desktop_job_implemented_desc"
  },
  {
    kind: "desktop_job_failed",
    labelKey: "notifications.desktop_job_failed_label",
    descKey: "notifications.desktop_job_failed_desc"
  }
]

export function NotificationsSettingsRoute() {
  const { t } = useT("settings")
  usePageTitle(t("notifications.heading"))
  const [notice, setNotice] = useState<string | null>(null)

  return (
    <main aria-label={t("aria_notification_settings")} className="mx-auto max-w-4xl space-y-6 p-6">
      <header>
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">{t('notifications.heading')}</h1>
        <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">{t('notifications.description')}</p>
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      <NotificationPreferencesPanel onNotice={setNotice} />
    </main>
  )
}

function NotificationPreferencesPanel({ onNotice }: { onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const preferences = useQuery({
    queryKey,
    queryFn: fetchNotificationPreferences
  })
  const update = useMutation({
    mutationFn: ({ kind, enabled }: { kind: NotificationPreferenceKind; enabled: boolean }) => updateNotificationPreferences({ [kind]: enabled }),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || t('notifications.updated'))
    }
  })

  return (
    <section className="rounded border border-gray-200 bg-white p-5 dark:border-gray-700 dark:bg-gray-900">
      {preferences.isPending ? <p className="text-sm text-gray-500 dark:text-gray-400">{t('notifications.loading')}</p> : null}
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
  const { t } = useT("settings")
  return (
    <div className="space-y-6">
      <fieldset className="space-y-3">
        <legend className="text-sm font-medium text-gray-700 dark:text-gray-300">{t('notifications.section_label')}</legend>
        {notificationPreferenceKinds.map(({ kind, labelKey }) => (
          <label className="flex items-center justify-between gap-4 rounded border border-gray-200 px-3 py-2 text-sm dark:border-gray-700" key={kind}>
            <span className="font-medium text-gray-700 dark:text-gray-300">{t(labelKey)}</span>
            <input
              aria-label={t(labelKey)}
              checked={payload.notification_preferences[kind]}
              className="h-4 w-4 rounded border-gray-400"
              disabled={disabled}
              onChange={(event) => onChange(kind, event.target.checked)}
              type="checkbox"
            />
          </label>
        ))}
      </fieldset>

      <fieldset className="space-y-3">
        <legend className="text-sm font-medium text-gray-700 dark:text-gray-300">{t('notifications.desktop_heading')}</legend>
        {desktopNotificationPreferenceKinds.map(({ kind, labelKey, descKey }) => (
          <label className="flex items-start justify-between gap-4 rounded border border-gray-200 px-3 py-2 text-sm dark:border-gray-700" key={kind}>
            <span>
              <span className="block font-medium text-gray-700 dark:text-gray-300">{t(labelKey)}</span>
              <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t(descKey)}</span>
            </span>
            <input
              aria-label={t(labelKey)}
              checked={payload.notification_preferences[kind]}
              className="mt-1 h-4 w-4 rounded border-gray-400"
              disabled={disabled}
              onChange={(event) => onChange(kind, event.target.checked)}
              type="checkbox"
            />
          </label>
        ))}
      </fieldset>
    </div>
  )
}
