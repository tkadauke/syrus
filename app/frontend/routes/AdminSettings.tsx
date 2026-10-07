import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { SectionHeading } from "../components/Heading"
import type { FormEvent, ReactNode } from "react"
import { useEffect, useState } from "react"
import {
  clearAdminSettingSecret,
  fetchAdminSettings,
  startPlatformPolling,
  updateAdminSettings,
  type AdminSettingsPayload,
  type ClearableSecret,
  type PlatformPollingConnectorStatus
} from "../api/adminSettings"
import { Button } from "../components/Button"
import { Checkbox } from "../components/Checkbox"
import { Input } from "../components/Input"
import { NoticeToast } from "../components/NoticeToast"
import { Select } from "../components/Select"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"
import { useConfirm } from "../hooks/useConfirm"
import { Page } from "../components/ui"

const queryKey = ["admin", "settings"] as const

export function AdminSettings() {
  const { t } = useT("admin")
  const [notice, setNotice] = useState<string | null>(null)
  const settings = useQuery({
    queryKey,
    queryFn: fetchAdminSettings
  })

  return (
    <Page.Root aria-label={t("aria_settings")} gutter="responsive" size="default">
      <Page.Header className="block border-b border-gray-200 pb-4 dark:border-gray-700">
        <Page.HeadingGroup>
          <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("section_label")}</p>
          <Page.Title className="mt-1">{t("settings.heading")}</Page.Title>
        </Page.HeadingGroup>
      </Page.Header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {settings.isPending ? <PanelMessage>{t("settings.loading")}</PanelMessage> : null}
      {settings.isError ? <SettingsError error={settings.error} /> : null}
      {settings.isSuccess ? <SettingsView onNotice={setNotice} payload={settings.data} /> : null}
    </Page.Root>
  )
}

function SettingsView({ payload, onNotice }: { payload: AdminSettingsPayload; onNotice: (message: string | null) => void }) {
  const otherSecrets = payload.settings.clearable_secrets.filter(s => s.key !== "telegram_bot_token" && s.key !== "discord_bot_token")
  return (
    <>
      <TelegramSection onNotice={onNotice} payload={payload} />
      <DiscordSection onNotice={onNotice} payload={payload} />

      {otherSecrets.length > 0 && (
        <section className="divide-y divide-gray-200 dark:divide-gray-700 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
          {otherSecrets.map((secret) => (
            <SecretRow key={secret.key} onNotice={onNotice} secret={secret} />
          ))}
        </section>
      )}

      <SettingsForm onNotice={onNotice} payload={payload} />
    </>
  )
}

function SecretRow({ secret, onNotice }: { secret: ClearableSecret; onNotice: (message: string | null) => void }) {
  const { t } = useT("admin")
  const { confirm, dialog } = useConfirm()
  const queryClient = useQueryClient()
  const clearSecret = useMutation({
    mutationFn: () => clearAdminSettingSecret(secret.key),
    onSuccess: (payload) => {
      queryClient.setQueryData(queryKey, payload)
      onNotice(payload.message || `${secret.label} cleared.`)
    }
  })

  return (
    <div className="flex flex-col gap-3 p-4 sm:flex-row sm:items-center sm:justify-between">
      <div>
        <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{secret.label}</div>
        <div className={`mt-1 text-xs ${secret.set ? "text-gray-500 dark:text-gray-400" : "text-amber-700 dark:text-amber-300"}`}>
          {secret.set ? t("settings.currently_set") : t("settings.not_set")}
        </div>
      </div>
      {secret.set ? (
        <button
          className="self-start rounded bg-red-50 dark:bg-red-950/40 px-3 py-1.5 text-sm font-medium text-red-700 dark:text-red-300 hover:bg-red-100 dark:hover:bg-red-950/60 disabled:cursor-not-allowed disabled:text-red-300 sm:self-auto"
          disabled={clearSecret.isPending}
          onClick={async () => {
            if (await confirm({ message: t("settings.confirm_clear", { label: secret.label }), destructive: true })) {
              onNotice(null)
              clearSecret.mutate()
            }
          }}
          type="button"
        >
          {clearSecret.isPending ? t("settings.clearing") : t("settings.clear")}
        </button>
      ) : null}
      {clearSecret.isError ? <div className="text-xs text-red-700 dark:text-red-300" role="alert">{errorMessage(clearSecret.error, t("settings.error_clear"))}</div> : null}
      {dialog}
    </div>
  )
}

function SettingsForm({ payload, onNotice }: { payload: AdminSettingsPayload; onNotice: (message: string | null) => void }) {
  const { t } = useT("admin")
  const queryClient = useQueryClient()
  const [signupsOpen, setSignupsOpen] = useState(payload.settings.signups_open)
  const [gradeMaxIterations, setGradeMaxIterations] = useState(String(payload.settings.grade_max_iterations))
  const [adversarialReviewRounds, setAdversarialReviewRounds] = useState(String(payload.settings.adversarial_review_rounds))
  const [maxJobFailures, setMaxJobFailures] = useState(String(payload.settings.max_job_failures))
  const [mergeTrainMaxSize, setMergeTrainMaxSize] = useState(String(payload.settings.merge_train_max_size))
  const [mainConcernReportThreshold, setMainConcernReportThreshold] = useState(String(payload.settings.main_concern_report_threshold))
  const [reportIssueRepoSlug, setReportIssueRepoSlug] = useState(payload.settings.report_issue_repo_slug)
  const [videoRetentionDays, setVideoRetentionDays] = useState(String(payload.settings.video_retention_days))
  const [videoBudgetMb, setVideoBudgetMb] = useState(String(payload.settings.video_storage_budget_mb))
  const [telegramBotHandle, setTelegramBotHandle] = useState(payload.settings.telegram_bot_handle ?? "")
  const [maxConcurrentAgentRuns, setMaxConcurrentAgentRuns] = useState(String(payload.settings.max_concurrent_agent_runs))
  const [proactiveRebaseThreshold, setProactiveRebaseThreshold] = useState(String(payload.settings.proactive_rebase_commit_threshold))
  const [showWorkUnitDebug, setShowWorkUnitDebug] = useState(payload.settings.show_work_unit_debug)
  const [rebaseFailureCooldown, setRebaseFailureCooldown] = useState(String(payload.settings.rebase_failure_cooldown_minutes))
  const [workflowPreviewHealthCheckTimeout, setWorkflowPreviewHealthCheckTimeout] = useState(String(payload.settings.workflow_preview_health_check_timeout_seconds))
  const [workflowAdmissionControlEnabled, setWorkflowAdmissionControlEnabled] = useState(payload.settings.workflow_admission_control_enabled)
  const [workflowAdmissionPolicy, setWorkflowAdmissionPolicy] = useState<"whole_workflow" | "phase_aware">(payload.settings.workflow_admission_policy)
  const [chatCodingWorkspaceBudgetMb, setChatCodingWorkspaceBudgetMb] = useState(String(payload.settings.chat_coding_workspace_budget_mb))
  const update = useMutation({
    mutationFn: () => updateAdminSettings({
      signups_open: signupsOpen,
      grade_max_iterations: Number(gradeMaxIterations),
      adversarial_review_rounds: Number(adversarialReviewRounds),
      max_job_failures: Number(maxJobFailures),
      merge_train_max_size: Number(mergeTrainMaxSize),
      main_concern_report_threshold: Number(mainConcernReportThreshold),
      report_issue_repo_slug: reportIssueRepoSlug,
      video_retention_days: Number(videoRetentionDays),
      video_storage_budget_mb: Number(videoBudgetMb),
      telegram_bot_handle: telegramBotHandle,
      max_concurrent_agent_runs: Number(maxConcurrentAgentRuns),
      proactive_rebase_commit_threshold: Number(proactiveRebaseThreshold),
      show_work_unit_debug: showWorkUnitDebug,
      rebase_failure_cooldown_minutes: Number(rebaseFailureCooldown),
      workflow_preview_health_check_timeout_seconds: Number(workflowPreviewHealthCheckTimeout),
      workflow_admission_control_enabled: workflowAdmissionControlEnabled,
      workflow_admission_policy: workflowAdmissionPolicy,
      chat_coding_workspace_budget_mb: Number(chatCodingWorkspaceBudgetMb)
    }),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || t("settings.settings_updated"))
    }
  })

  useEffect(() => {
    setSignupsOpen(payload.settings.signups_open)
    setGradeMaxIterations(String(payload.settings.grade_max_iterations))
    setAdversarialReviewRounds(String(payload.settings.adversarial_review_rounds))
    setMaxJobFailures(String(payload.settings.max_job_failures))
    setMergeTrainMaxSize(String(payload.settings.merge_train_max_size))
    setMainConcernReportThreshold(String(payload.settings.main_concern_report_threshold))
    setReportIssueRepoSlug(payload.settings.report_issue_repo_slug)
    setVideoRetentionDays(String(payload.settings.video_retention_days))
    setVideoBudgetMb(String(payload.settings.video_storage_budget_mb))
    setTelegramBotHandle(payload.settings.telegram_bot_handle ?? "")
    setMaxConcurrentAgentRuns(String(payload.settings.max_concurrent_agent_runs))
    setProactiveRebaseThreshold(String(payload.settings.proactive_rebase_commit_threshold))
    setShowWorkUnitDebug(payload.settings.show_work_unit_debug)
    setRebaseFailureCooldown(String(payload.settings.rebase_failure_cooldown_minutes))
    setWorkflowPreviewHealthCheckTimeout(String(payload.settings.workflow_preview_health_check_timeout_seconds))
    setWorkflowAdmissionControlEnabled(payload.settings.workflow_admission_control_enabled)
    setWorkflowAdmissionPolicy(payload.settings.workflow_admission_policy)
    setChatCodingWorkspaceBudgetMb(String(payload.settings.chat_coding_workspace_budget_mb))
  }, [payload.settings.signups_open, payload.settings.grade_max_iterations, payload.settings.adversarial_review_rounds, payload.settings.max_job_failures, payload.settings.merge_train_max_size, payload.settings.main_concern_report_threshold, payload.settings.report_issue_repo_slug, payload.settings.video_retention_days, payload.settings.video_storage_budget_mb, payload.settings.telegram_bot_handle, payload.settings.max_concurrent_agent_runs, payload.settings.proactive_rebase_commit_threshold, payload.settings.show_work_unit_debug, payload.settings.rebase_failure_cooldown_minutes, payload.settings.workflow_preview_health_check_timeout_seconds, payload.settings.workflow_admission_control_enabled, payload.settings.workflow_admission_policy, payload.settings.chat_coding_workspace_budget_mb])

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    update.mutate()
  }

  return (
    <form className="space-y-4 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-6" onSubmit={submit}>
      <Checkbox
        checked={signupsOpen}
        className="mt-1"
        label={
          <>
            <span className="block text-sm font-medium text-gray-700 dark:text-gray-200">{t("settings.signups_open_label")}</span>
            <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t("settings.signups_open_help")}</span>
          </>
        }
        onChange={(event) => setSignupsOpen(event.target.checked)}
      />

      <div>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="admin-settings-report-issue-repo">{t("settings.report_issue_repo_slug_label")}</label>
        <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t("settings.report_issue_repo_slug_help")}</span>
        <Input
          className="mt-1 max-w-md"
          id="admin-settings-report-issue-repo"
          onChange={(event) => setReportIssueRepoSlug(event.target.value)}
          value={reportIssueRepoSlug}
        />
      </div>

      <div>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="admin-settings-telegram-handle">{t("settings.telegram_bot_handle_label")}</label>
        <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t("settings.telegram_bot_handle_help")}</span>
        <Input
          className="mt-1 max-w-sm"
          id="admin-settings-telegram-handle"
          onChange={(event) => setTelegramBotHandle(event.target.value)}
          value={telegramBotHandle}
        />
      </div>

      <div className="grid gap-4 md:grid-cols-2">
        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="admin-settings-grade-max-iterations">{t("settings.grade_max_iterations_label")}</label>
          <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t("settings.grade_max_iterations_help")}</span>
          <Input
            className="mt-1 w-32"
            fullWidth={false}
            id="admin-settings-grade-max-iterations"
            max={10}
            min={1}
            onChange={(event) => setGradeMaxIterations(event.target.value)}
            type="number"
            value={gradeMaxIterations}
          />
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="admin-settings-adversarial-review-rounds">{t("settings.adversarial_review_rounds_label")}</label>
          <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t("settings.adversarial_review_rounds_help")}</span>
          <Input
            className="mt-1 w-32"
            fullWidth={false}
            id="admin-settings-adversarial-review-rounds"
            max={10}
            min={0}
            onChange={(event) => setAdversarialReviewRounds(event.target.value)}
            type="number"
            value={adversarialReviewRounds}
          />
        </div>
      </div>

      <div className="grid gap-4 md:grid-cols-2">
        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="admin-settings-max-job-failures">{t("settings.max_job_failures_label")}</label>
          <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t("settings.max_job_failures_help")}</span>
          <Input
            className="mt-1 w-32"
            fullWidth={false}
            id="admin-settings-max-job-failures"
            min={1}
            onChange={(event) => setMaxJobFailures(event.target.value)}
            type="number"
            value={maxJobFailures}
          />
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="admin-settings-main-concern-report-threshold">{t("settings.main_concern_report_threshold_label")}</label>
          <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t("settings.main_concern_report_threshold_help")}</span>
          <Input
            className="mt-1 w-32"
            fullWidth={false}
            id="admin-settings-main-concern-report-threshold"
            min={1}
            onChange={(event) => setMainConcernReportThreshold(event.target.value)}
            type="number"
            value={mainConcernReportThreshold}
          />
        </div>
      </div>

      <div className="grid gap-4 md:grid-cols-2">
        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="admin-settings-merge-train-max-size">{t("settings.merge_train_max_size_label")}</label>
          <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t("settings.merge_train_max_size_help")}</span>
          <Input
            className="mt-1 w-32"
            fullWidth={false}
            id="admin-settings-merge-train-max-size"
            min={1}
            onChange={(event) => setMergeTrainMaxSize(event.target.value)}
            type="number"
            value={mergeTrainMaxSize}
          />
        </div>
      </div>

      <div>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="admin-settings-video-retention">{t("settings.video_retention_label")}</label>
        <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t("settings.video_retention_help")}</span>
        <Input
          className="mt-1 w-32"
          fullWidth={false}
          id="admin-settings-video-retention"
          min={1}
          onChange={(event) => setVideoRetentionDays(event.target.value)}
          type="number"
          value={videoRetentionDays}
        />
      </div>

      <div>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="admin-settings-video-budget">{t("settings.video_budget_label")}</label>
        <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t("settings.video_budget_help")}</span>
        <Input
          className="mt-1 w-32"
          fullWidth={false}
          id="admin-settings-video-budget"
          min={0}
          onChange={(event) => setVideoBudgetMb(event.target.value)}
          type="number"
          value={videoBudgetMb}
        />
      </div>

      <div>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="admin-settings-chat-coding-workspace-budget">{t("settings.chat_coding_workspace_budget_label")}</label>
        <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t("settings.chat_coding_workspace_budget_help")}</span>
        <Input
          className="mt-1 w-32"
          fullWidth={false}
          id="admin-settings-chat-coding-workspace-budget"
          min={0}
          onChange={(event) => setChatCodingWorkspaceBudgetMb(event.target.value)}
          type="number"
          value={chatCodingWorkspaceBudgetMb}
        />
      </div>

      <div>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="admin-settings-max-agent-runs">{t("settings.max_concurrent_agent_runs_label")}</label>
        <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t("settings.max_concurrent_agent_runs_help")}</span>
        <Input
          className="mt-1 w-32"
          fullWidth={false}
          id="admin-settings-max-agent-runs"
          min={0}
          onChange={(event) => setMaxConcurrentAgentRuns(event.target.value)}
          type="number"
          value={maxConcurrentAgentRuns}
        />
      </div>

      <div>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="admin-settings-proactive-rebase-threshold">{t("settings.proactive_rebase_commit_threshold_label")}</label>
        <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t("settings.proactive_rebase_commit_threshold_help")}</span>
        <Input
          className="mt-1 w-32"
          fullWidth={false}
          id="admin-settings-proactive-rebase-threshold"
          min={1}
          onChange={(event) => setProactiveRebaseThreshold(event.target.value)}
          type="number"
          value={proactiveRebaseThreshold}
        />
      </div>

      <Checkbox
        checked={showWorkUnitDebug}
        className="mt-1"
        label={
          <>
            <span className="block text-sm font-medium text-gray-700 dark:text-gray-200">{t("settings.show_work_unit_debug_label")}</span>
            <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t("settings.show_work_unit_debug_help")}</span>
          </>
        }
        onChange={(event) => setShowWorkUnitDebug(event.target.checked)}
      />

      <div>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="admin-settings-rebase-failure-cooldown">{t("settings.rebase_failure_cooldown_label")}</label>
        <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t("settings.rebase_failure_cooldown_help")}</span>
        <Input
          className="mt-1 w-32"
          fullWidth={false}
          id="admin-settings-rebase-failure-cooldown"
          min={0}
          onChange={(event) => setRebaseFailureCooldown(event.target.value)}
          type="number"
          value={rebaseFailureCooldown}
        />
      </div>

      <div>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="admin-settings-workflow-preview-health-check-timeout">{t("settings.workflow_preview_health_check_timeout_label")}</label>
        <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t("settings.workflow_preview_health_check_timeout_help")}</span>
        <Input
          className="mt-1 w-32"
          fullWidth={false}
          id="admin-settings-workflow-preview-health-check-timeout"
          min={1}
          onChange={(event) => setWorkflowPreviewHealthCheckTimeout(event.target.value)}
          type="number"
          value={workflowPreviewHealthCheckTimeout}
        />
      </div>

      <div className={`rounded border px-3 py-3 ${workflowAdmissionControlEnabled ? "border-gray-200 dark:border-gray-700" : "border-amber-300 bg-amber-50 dark:border-amber-700 dark:bg-amber-950/30"}`}>
        <Checkbox
          checked={workflowAdmissionControlEnabled}
          className="mt-1"
          label={
            <>
              <span className="block text-sm font-medium text-gray-700 dark:text-gray-200">{t("settings.workflow_admission_control_label")}</span>
              <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t("settings.workflow_admission_control_help")}</span>
              {!workflowAdmissionControlEnabled ? <span className="mt-2 block text-xs font-medium text-amber-800 dark:text-amber-200">{t("settings.workflow_admission_control_warning")}</span> : null}
              {payload.settings.workflow_admission_control_changed_at ? (
                <span className="mt-2 block text-xs text-gray-500 dark:text-gray-400">
                  {t("settings.workflow_admission_control_changed", {
                    at: payload.settings.workflow_admission_control_changed_at,
                    actor: payload.settings.workflow_admission_control_changed_by?.display_name || payload.settings.workflow_admission_control_changed_by?.email_address || t("settings.workflow_admission_control_unknown_actor")
                  })}
                </span>
              ) : null}
            </>
          }
          onChange={(event) => setWorkflowAdmissionControlEnabled(event.target.checked)}
        />
        <div className="mt-3">
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-200" htmlFor="admin-settings-workflow-admission-policy">{t("settings.workflow_admission_policy_label")}</label>
          <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">{t("settings.workflow_admission_policy_help")}</span>
          <Select
            className="mt-2"
            fullWidth={false}
            id="admin-settings-workflow-admission-policy"
            onChange={(event) => setWorkflowAdmissionPolicy(event.target.value as "whole_workflow" | "phase_aware")}
            value={workflowAdmissionPolicy}
          >
            <option value="whole_workflow">{t("settings.workflow_admission_policy_whole_workflow")}</option>
            <option value="phase_aware">{t("settings.workflow_admission_policy_phase_aware")}</option>
          </Select>
        </div>
      </div>

      <Button
        disabled={update.isPending}
        type="submit"
      >
        {update.isPending ? t("settings.saving") : t("settings.save")}
      </Button>
      {update.isError ? <p className="text-sm text-red-700 dark:text-red-300" role="alert">{errorMessage(update.error, t("settings.error_update"))}</p> : null}
    </form>
  )
}

function TelegramSection({ payload, onNotice }: { payload: AdminSettingsPayload; onNotice: (message: string | null) => void }) {
  const { t } = useT("admin")
  const { confirm, dialog } = useConfirm()
  const queryClient = useQueryClient()
  const [tokenInput, setTokenInput] = useState("")

  const telegramSecret = payload.settings.clearable_secrets.find(s => s.key === "telegram_bot_token")
  const tokenSet = telegramSecret?.set ?? false

  const saveToken = useMutation({
    mutationFn: () => updateAdminSettings({ telegram_bot_token: tokenInput }),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setTokenInput("")
      onNotice(updated.message || t("settings.settings_updated"))
    }
  })

  const clearToken = useMutation({
    mutationFn: () => clearAdminSettingSecret("telegram_bot_token"),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || t("settings.settings_updated"))
    }
  })

  return (
    <section className="space-y-4 rounded border border-border bg-surface p-6">
      <SectionHeading>{t("settings.telegram_heading")}</SectionHeading>

      <div className="text-xs text-text-muted">{tokenSet ? t("settings.currently_set") : t("settings.not_set")}</div>

      <div className="flex flex-wrap gap-2">
        <Input
          aria-label={t("settings.telegram_token_label")}
          autoComplete="off"
          className="flex-1 min-w-48"
          onChange={(e) => setTokenInput(e.target.value)}
          placeholder={t("settings.telegram_token_placeholder")}
          type="password"
          value={tokenInput}
        />
        <Button
          disabled={saveToken.isPending || !tokenInput.trim()}
          onClick={() => { onNotice(null); saveToken.mutate() }}
        >
          {saveToken.isPending ? t("settings.saving") : t("settings.telegram_save_token")}
        </Button>
        {tokenSet && (
          <Button
            disabled={clearToken.isPending}
            onClick={async () => {
              if (await confirm({ message: t("settings.telegram_token_clear_confirm"), destructive: true })) {
                onNotice(null)
                clearToken.mutate()
              }
            }}
            variant="danger"
          >
            {clearToken.isPending ? t("settings.clearing") : t("settings.clear")}
          </Button>
        )}
      </div>

      <PlatformPollingControl disabled={!tokenSet} label={t("settings.telegram_heading")} platform="telegram" />

      {saveToken.isError ? <p className="text-xs text-danger" role="alert">{errorMessage(saveToken.error, t("settings.error_update"))}</p> : null}
      {clearToken.isError ? <p className="text-xs text-danger" role="alert">{errorMessage(clearToken.error, t("settings.error_clear"))}</p> : null}
      {dialog}
    </section>
  )
}

function DiscordSection({ payload, onNotice }: { payload: AdminSettingsPayload; onNotice: (message: string | null) => void }) {
  const { t } = useT("admin")
  const { confirm, dialog } = useConfirm()
  const queryClient = useQueryClient()
  const [tokenInput, setTokenInput] = useState("")

  const discordSecret = payload.settings.clearable_secrets.find(s => s.key === "discord_bot_token")
  const tokenSet = discordSecret?.set ?? false

  const saveToken = useMutation({
    mutationFn: () => updateAdminSettings({ discord_bot_token: tokenInput }),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setTokenInput("")
      onNotice(updated.message || t("settings.settings_updated"))
    }
  })

  const clearToken = useMutation({
    mutationFn: () => clearAdminSettingSecret("discord_bot_token"),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || t("settings.settings_updated"))
    }
  })

  return (
    <section className="space-y-4 rounded border border-border bg-surface p-6">
      <SectionHeading>{t("settings.discord_heading")}</SectionHeading>

      <div className="text-xs text-text-muted">{tokenSet ? t("settings.currently_set") : t("settings.not_set")}</div>

      <div className="flex flex-wrap gap-2">
        <Input
          aria-label={t("settings.discord_token_label")}
          autoComplete="off"
          className="flex-1 min-w-48"
          onChange={(e) => setTokenInput(e.target.value)}
          placeholder={t("settings.discord_token_placeholder")}
          type="password"
          value={tokenInput}
        />
        <Button
          disabled={saveToken.isPending || !tokenInput.trim()}
          onClick={() => { onNotice(null); saveToken.mutate() }}
        >
          {saveToken.isPending ? t("settings.saving") : t("settings.discord_save_token")}
        </Button>
        {tokenSet && (
          <Button
            disabled={clearToken.isPending}
            onClick={async () => {
              if (await confirm({ message: t("settings.discord_token_clear_confirm"), destructive: true })) {
                onNotice(null)
                clearToken.mutate()
              }
            }}
            variant="danger"
          >
            {clearToken.isPending ? t("settings.clearing") : t("settings.clear")}
          </Button>
        )}
      </div>

      <PlatformPollingControl disabled={!tokenSet} label={t("settings.discord_heading")} platform="discord" />

      {saveToken.isError ? <p className="text-xs text-danger" role="alert">{errorMessage(saveToken.error, t("settings.error_update"))}</p> : null}
      {clearToken.isError ? <p className="text-xs text-danger" role="alert">{errorMessage(clearToken.error, t("settings.error_clear"))}</p> : null}
      {dialog}
    </section>
  )
}

// Shared "Start polling" control for a single platform's connector. The
// backend's POST /api/v1/app/admin/platform_polling/start call always
// (re)primes every core and plugin connector in one request (not just this
// platform's), so every section's button triggers the same underlying call;
// this component only reads and renders the slice of the response that
// belongs to its own `platform` key, so a Telegram click can never be
// reported as a Discord result or vice versa.
const POLLING_STATUS_MESSAGE_KEYS: Record<PlatformPollingConnectorStatus, string> = {
  started: "polling_started",
  already_running: "polling_already_running",
  not_configured: "polling_not_configured",
  error: "polling_error"
}

function PlatformPollingControl({ platform, label, disabled }: { platform: string; label: string; disabled: boolean }) {
  const { t } = useT("admin")
  const startPolling = useMutation({ mutationFn: startPlatformPolling })

  const connector = startPolling.data?.connectors.find((c) => c.platform === platform)
  const statusMessage = connector ? t(`settings.${POLLING_STATUS_MESSAGE_KEYS[connector.status]}`, { platform: label }) : null

  return (
    <div className="space-y-1">
      <Button
        disabled={startPolling.isPending || disabled}
        onClick={() => startPolling.mutate()}
        variant="secondary"
      >
        {startPolling.isPending ? t("settings.polling_starting") : t("settings.polling_start")}
      </Button>

      {statusMessage ? <p className="text-xs text-text-muted">{statusMessage}</p> : null}
      {startPolling.isError ? <p className="text-xs text-danger" role="alert">{t("settings.polling_error", { platform: label })}</p> : null}
    </div>
  )
}

function SettingsError({ error }: { error: Error }) {
  const { t } = useT("admin")
  return <PanelMessage tone="error">{errorMessage(error, t("settings.error_load"))}</PanelMessage>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`p-4 text-sm ${tone === "error" ? "text-danger" : "text-text-secondary"}`}>{children}</div>
}
