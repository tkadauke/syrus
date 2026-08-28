import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Checkbox } from "../components/Checkbox"
import { PageHeading } from "../components/Heading"
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

export function NotificationsSettingsRoute() {
  const { t } = useT("settings")
  usePageTitle(t("notifications.heading"))
  const [notice, setNotice] = useState<string | null>(null)

  return (
    <main aria-label={t("aria_notification_settings")} className="mx-auto max-w-4xl space-y-6 p-6">
      <header>
        <PageHeading>{t('notifications.heading')}</PageHeading>
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
            <Checkbox
              aria-label={t(labelKey)}
              checked={payload.notification_preferences[kind]}
              disabled={disabled}
              onChange={(event) => onChange(kind, event.target.checked)}
            />
          </label>
        ))}
      </fieldset>
    </div>
  )
}
