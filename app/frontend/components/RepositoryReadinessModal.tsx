import { useMutation, useQueryClient } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { fetchRepositoryReadiness, overrideRepositoryReadinessProbe, startRepositoryReadinessProbe } from "../api/repositories"
import { useT } from "../hooks/useT"
import { buttonClasses } from "./Button"
import { Modal } from "./Modal"
import { TonePill } from "./StatusPill"

export type RepositoryReadiness = Awaited<ReturnType<typeof fetchRepositoryReadiness>>["readiness"]

export function readinessTone(status: RepositoryReadiness["status"]) {
  if (status === "ready") return "green" as const
  if (status === "ready_with_warnings") return "amber" as const
  return "red" as const
}

export function RepositoryReadinessModal({
  open,
  onClose,
  repositoryId,
  report
}: {
  open: boolean
  onClose: () => void
  repositoryId: number | string
  report: RepositoryReadiness
}) {
  const { t } = useT("common")
  const queryClient = useQueryClient()
  const titleId = `repository-readiness-title-${repositoryId}`
  const refresh = () => queryClient.invalidateQueries({ queryKey: ["repository-readiness", repositoryId] })
  const runProbe = useMutation({ mutationFn: () => startRepositoryReadinessProbe(repositoryId), onSuccess: refresh })
  const overrideProbe = useMutation({ mutationFn: (probeId: number) => overrideRepositoryReadinessProbe(repositoryId, probeId), onSuccess: refresh })

  return (
    <Modal
      className="max-h-[85vh] w-full max-w-3xl overflow-y-auto rounded-[var(--radius-panel)] bg-surface p-5 shadow-[var(--shadow-panel)]"
      labelledBy={titleId}
      onClose={onClose}
      open={open}
    >
      <div className="flex items-start justify-between gap-3 border-b border-border-subtle pb-4">
        <div>
          <h2 className="text-lg font-semibold text-text-primary" id={titleId}>
            {t("onboarding.readiness_label")}
          </h2>
          <div className="mt-1">
            <TonePill tone={readinessTone(report.status)}>{report.summary}</TonePill>
          </div>
        </div>
        <button className={buttonClasses("secondary", "sm")} onClick={onClose} type="button">
          {t("onboarding.readiness_close")}
        </button>
      </div>

      <ul className="mt-4 space-y-1 text-sm text-text-secondary">
        {report.checks.map((check, index) => (
          <MarkerRow marker={check.level === "pass" ? "✓" : check.level === "warning" ? "!" : "×"} key={`${check.key}-${index}`}>
            {check.message}
          </MarkerRow>
        ))}
      </ul>
      <CommandList commands={report.prepare_commands} label={t("onboarding.readiness_prepare")} />
      <CommandList commands={report.grader_commands} label={t("onboarding.readiness_graders")} />
      {report.execution_scopes.length > 0 ? (
        <>
          <h3 className="mt-3 text-xs font-medium uppercase text-text-muted">{t("onboarding.readiness_workers")}</h3>
          <ul className="mt-1 space-y-1 text-xs text-text-secondary">
            {report.execution_scopes.map((scope) => (
              <MarkerRow marker={scope.worker_available ? "✓" : "×"} key={scope.key}>
                {scope.label}: {formatCapabilities(scope.capabilities)} · {scope.queue_name}
                {scope.command ? ` · $ ${scope.command}` : ""}
              </MarkerRow>
            ))}
          </ul>
        </>
      ) : null}
      <p className="mt-3 text-xs text-text-muted">{t("onboarding.readiness_advisory")}</p>
      <div className="mt-4 border-t border-border-subtle pt-4">
        <div className="flex items-center justify-between gap-3">
          <h3 className="text-sm font-medium text-text-primary">{t("onboarding.readiness_probe")}</h3>
          <button
            className={buttonClasses("secondary", "sm")}
            disabled={runProbe.isPending || report.execution_probe?.status === "queued" || report.execution_probe?.status === "running"}
            onClick={() => runProbe.mutate()}
            type="button"
          >
            {report.execution_probe ? t("onboarding.readiness_probe_retry") : t("onboarding.readiness_probe_run")}
          </button>
        </div>
        {report.execution_probe ? (
          <ExecutionProbe probe={report.execution_probe} onOverride={() => overrideProbe.mutate(report.execution_probe!.id)} />
        ) : (
          <p className="mt-1 text-xs text-text-muted">{t("onboarding.readiness_probe_description")}</p>
        )}
      </div>
    </Modal>
  )
}

export function MarkerRow({ marker, children }: { marker: string; children: ReactNode }) {
  return (
    <li className="grid grid-cols-[1.25rem_1fr] items-start">
      <span aria-hidden="true" className="w-5 text-center font-semibold">
        {marker}
      </span>
      <span>{children}</span>
    </li>
  )
}

function ExecutionProbe({ probe, onOverride }: { probe: NonNullable<RepositoryReadiness["execution_probe"]>; onOverride: () => void }) {
  const { t } = useT("common")
  return (
    <div className="mt-2 space-y-2 text-xs text-text-secondary">
      <p>
        <strong>{probe.status}</strong>
        {probe.result.summary ? ` — ${probe.result.summary}` : ""}
      </p>
      {probe.result.duration_s != null ? (
        <p>
          {t("onboarding.readiness_probe_metrics", {
            duration: probe.result.duration_s,
            bytes: probe.result.disk_growth_bytes ?? 0,
            cleanup: probe.result.cleanup
          })}
        </p>
      ) : null}
      {probe.result.missing_executables?.length ? (
        <p>{t("onboarding.readiness_probe_missing_executables", { names: probe.result.missing_executables.join(", ") })}</p>
      ) : null}
      {probe.result.missing_services?.length ? (
        <p>{t("onboarding.readiness_probe_missing_services", { names: probe.result.missing_services.join(", ") })}</p>
      ) : null}
      {probe.result.commands?.length ? (
        <ul className="space-y-1">
          {probe.result.commands.map((command, index) => (
            <MarkerRow marker={command.success ? "✓" : "×"} key={`${command.kind}-${index}`}>
              <details>
                <summary>
                  {command.kind}: $ {command.command}
                </summary>
                {command.output_tail ? (
                  <pre className="mt-1 max-h-40 overflow-auto whitespace-pre-wrap rounded bg-surface-inset p-2">{command.output_tail}</pre>
                ) : null}
              </details>
            </MarkerRow>
          ))}
        </ul>
      ) : null}
      {probe.status === "blocked" && !probe.warning_override ? (
        <button className={buttonClasses("secondary", "sm")} onClick={onOverride} type="button">
          {t("onboarding.readiness_probe_override")}
        </button>
      ) : null}
    </div>
  )
}

function formatCapabilities(capabilities: Record<string, string[]>) {
  return Object.entries(capabilities)
    .map(([dimension, values]) => `${dimension}=${values.join("/")}`)
    .join(", ")
}

function CommandList({ commands, label }: { commands: string[]; label: string }) {
  if (commands.length === 0) return null
  return (
    <div className="mt-3">
      <h3 className="text-xs font-medium uppercase text-text-muted">{label}</h3>
      <pre className="mt-1 overflow-x-auto rounded bg-surface-inset p-3 text-xs text-text-primary">{commands.map((command) => `$ ${command}`).join("\n")}</pre>
    </div>
  )
}
