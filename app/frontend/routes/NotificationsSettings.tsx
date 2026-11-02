import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { Checkbox } from "../components/Checkbox"
import { Input } from "../components/Input"
import { PageHeading } from "../components/Heading"
import { useState } from "react"
import { Link, useLocation } from "react-router-dom"
import {
  fetchNotificationPreferences,
  updateApprovalDeliveryPreferences,
  updateNotificationPreferences,
  type NotificationPreferenceKind,
  type NotificationPreferencesPayload
} from "../api/notifications"
import { NoticeToast } from "../components/NoticeToast"
import { PanelMessage } from "../components/PanelMessage"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { errorMessage } from "../lib/errorMessage"
import { routePrefix, withRoutePrefix } from "../lib/routing"

const queryKey = ["notification_preferences"] as const

const notificationPreferenceKinds: Array<{ kind: NotificationPreferenceKind; labelKey: string }> = [
  { kind: "chat_mention", labelKey: "notifications.pref_chat_mention" },
  { kind: "job_failed", labelKey: "notifications.pref_job_failed" },
  { kind: "job_implemented", labelKey: "notifications.pref_job_implemented" },
  { kind: "pr_comment_addressed", labelKey: "notifications.pref_pr_comment_addressed" },
  { kind: "pr_merged", labelKey: "notifications.pref_pr_merged" },
  { kind: "epic_completed", labelKey: "notifications.pref_epic_completed" },
  { kind: "main_inconclusive", labelKey: "notifications.pref_main_inconclusive" },
  { kind: "investigation_escalated", labelKey: "notifications.pref_investigation_escalated" }
]

export function NotificationsSettingsRoute() {
  const { t } = useT("settings")
  usePageTitle(t("notifications.heading"))
  const [notice, setNotice] = useState<string | null>(null)
  const prefix = routePrefix(useLocation().pathname)

  return (
    <main aria-label={t("aria_notification_settings")} className="mx-auto max-w-4xl space-y-6 p-6">
      <header>
        <PageHeading>{t("notifications.heading")}</PageHeading>
        <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">{t("notifications.description")}</p>
        <p className="mt-1 text-sm text-text-secondary">
          {t("notifications.see_also")}{" "}
          <Link className="text-brand underline hover:no-underline" to={withRoutePrefix("/settings/connected_platforms", prefix)}>
            {t("nav.connected_platforms")}
          </Link>
          .
        </p>
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
    onMutate: async ({ kind, enabled }) => {
      await queryClient.cancelQueries({ queryKey })
      const previous = queryClient.getQueryData<NotificationPreferencesPayload>(queryKey)
      if (previous) {
        queryClient.setQueryData<NotificationPreferencesPayload>(queryKey, {
          ...previous,
          notification_preferences: { ...previous.notification_preferences, [kind]: enabled }
        })
      }
      return { previous }
    },
    onError: (_error, _variables, context) => {
      if (context?.previous) queryClient.setQueryData(queryKey, context.previous)
    },
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || t("notifications.updated"))
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey })
  })

  return (
    <section className="rounded border border-gray-200 bg-white p-5 dark:border-gray-700 dark:bg-gray-900">
      {preferences.isPending ? <p className="text-sm text-gray-500 dark:text-gray-400">{t("notifications.loading")}</p> : null}
      {preferences.isError ? <PanelMessage tone="error">{errorMessage(preferences.error, t("notifications.load_error"))}</PanelMessage> : null}
      {update.isError ? <PanelMessage tone="error">{errorMessage(update.error, t("notifications.update_error"))}</PanelMessage> : null}
      {preferences.isSuccess ? (
        <div className="space-y-8">
          <NotificationPreferenceToggles
            disabled={update.isPending}
            onChange={(kind, enabled) => {
              onNotice(null)
              update.mutate({ kind, enabled })
            }}
            payload={preferences.data}
          />
          <ApprovalDeliverySettings payload={preferences.data} onNotice={onNotice} />
        </div>
      ) : null}
    </section>
  )
}

function ApprovalDeliverySettings({ payload, onNotice }: { payload: NotificationPreferencesPayload; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const update = useMutation({
    mutationFn: updateApprovalDeliveryPreferences,
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || t("notifications.updated"))
    }
  })
  const preferences = payload.approval_delivery_preferences || {
    enabled: true,
    batch_minutes: 10,
    quiet_hours_enabled: false,
    quiet_hours_start: "22:00",
    quiet_hours_end: "07:00",
    time_zone: "UTC"
  }
  const save = (change: Parameters<typeof updateApprovalDeliveryPreferences>[0]) => {
    onNotice(null)
    update.mutate(change)
  }

  return (
    <fieldset className="space-y-3 border-t border-border pt-6">
      <legend className="text-sm font-medium text-text-primary">{t("notifications.approval_delivery")}</legend>
      <p className="text-sm text-text-secondary">{t("notifications.approval_delivery_help")}</p>
      <Toggle
        label={t("notifications.approval_external")}
        checked={preferences.enabled}
        disabled={update.isPending}
        onChange={(value) => save({ enabled: value })}
      />
      <label className="grid gap-1 text-sm text-text-secondary">
        <span>{t("notifications.approval_batch")}</span>
        <Input
          fullWidth={false}
          type="number"
          min="0"
          max="60"
          value={preferences.batch_minutes}
          onChange={(event) => save({ batch_minutes: Number(event.target.value) })}
        />
      </label>
      <Toggle
        label={t("notifications.approval_quiet")}
        checked={preferences.quiet_hours_enabled}
        disabled={update.isPending}
        onChange={(value) => save({ quiet_hours_enabled: value })}
      />
      <div className="flex flex-wrap gap-3">
        <label className="grid gap-1 text-sm text-text-secondary">
          <span>{t("notifications.quiet_start")}</span>
          <Input fullWidth={false} type="time" value={preferences.quiet_hours_start} onChange={(event) => save({ quiet_hours_start: event.target.value })} />
        </label>
        <label className="grid gap-1 text-sm text-text-secondary">
          <span>{t("notifications.quiet_end")}</span>
          <Input fullWidth={false} type="time" value={preferences.quiet_hours_end} onChange={(event) => save({ quiet_hours_end: event.target.value })} />
        </label>
        <label className="grid gap-1 text-sm text-text-secondary">
          <span>{t("notifications.time_zone")}</span>
          <Input fullWidth={false} value={preferences.time_zone} onChange={(event) => save({ time_zone: event.target.value })} />
        </label>
      </div>
      {update.isError ? <PanelMessage tone="error">{errorMessage(update.error, t("notifications.update_error"))}</PanelMessage> : null}
    </fieldset>
  )
}

function Toggle({ label, checked, disabled, onChange }: { label: string; checked: boolean; disabled: boolean; onChange: (value: boolean) => void }) {
  return (
    <label className="flex items-center justify-between gap-4 rounded border border-border px-3 py-2 text-sm">
      <span className="font-medium text-text-primary">{label}</span>
      <Checkbox aria-label={label} checked={checked} disabled={disabled} onChange={(event) => onChange(event.target.checked)} />
    </label>
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
        <legend className="text-sm font-medium text-gray-700 dark:text-gray-300">{t("notifications.section_label")}</legend>
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
