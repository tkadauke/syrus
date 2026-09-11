import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { routePrefix } from "@app/lib/routing"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useState } from "react"
import { Link, useLocation, useParams } from "react-router-dom"
import { NoticeToast } from "@app/components/NoticeToast"
import {
  deleteRepositoryScheduledTask,
  fetchRepositoryScheduledTasks,
  updateRepositoryScheduledTask,
  type RepositoryScheduledTask,
  type RepositoryScheduledTasksPayload
} from "../api/scheduledTasks"
import { RepositoryPageShell } from "@app/components/RepositoryPageShell"
import { PageHeading, SectionHeading } from "@app/components/Heading"
import { toRomanDate } from "@app/lib/romanCalendar"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { PanelMessage } from "@app/components/PanelMessage"
import { errorMessage } from "@app/lib/errorMessage"
import { useConfirm } from "@app/hooks/useConfirm"
import { Button, buttonClasses } from "@app/components/Button"
import { DataTable } from "@app/components/ui"

export function RepositoryScheduledTasksRoute() {
  const { t } = useT("settings")
  const location = useLocation()
  const params = useParams()
  // The sidebar_pages route declares this segment as `:repository_id`
  // (snake_case), not `:repositoryId` -- unlike the core repo_tabs dispatcher
  // route. Reading the wrong key left this permanently empty, so the query
  // never ran and the tab was stuck on "Loading scheduled tasks...".
  const repositoryId = params.repository_id || ""
  const prefix = routePrefix(location.pathname)
  const tasks = useQuery({
    queryKey: ["repositories", repositoryId, "scheduled_tasks"],
    queryFn: () => fetchRepositoryScheduledTasks(repositoryId),
    enabled: repositoryId.length > 0
  })
  const payload = tasks.data
  const slug = payload?.repository.slug
  usePageTitle(slug ? t("page_title_repo_schedules", { slug }) : t("page_title_schedules"))

  return (
    <RepositoryPageShell
      activeTab="scheduled_tasks.repository"
      ariaLabel={t("aria_repo_scheduled_tasks")}
      heading={payload ? (
        <PageHeading mono>
          <Link className="hover:underline" to={`${prefix}${payload.repository.repository_path}`}>{payload.repository.slug}</Link>
        </PageHeading>
      ) : null}
      prefix={prefix}
      tabs={payload?.tabs ?? []}
    >
      {tasks.isPending ? <PanelMessage>{t("scheduled_tasks.loading")}</PanelMessage> : null}
      {tasks.isError ? <RepositoryScheduledTasksError error={tasks.error} /> : null}
      {payload ? <RepositoryScheduledTasksView payload={payload} prefix={prefix} /> : null}
    </RepositoryPageShell>
  )
}

function RepositoryScheduledTasksView({ payload, prefix }: { payload: RepositoryScheduledTasksPayload; prefix: string }) {
  const { t } = useT("settings")
  const { confirm, dialog } = useConfirm()
  const queryClient = useQueryClient()
  const [notice, setNotice] = useState<string | null>(payload.message || null)
  const queryKey = ["repositories", String(payload.repository.id), "scheduled_tasks"] as const
  const toggle = useMutation({
    mutationFn: ({ task, enabled }: { task: RepositoryScheduledTask; enabled: boolean }) => updateRepositoryScheduledTask(payload.repository.id, task.id, enabled),
    onSuccess: (updated) => {
      setNotice(updated.message || null)
      queryClient.setQueryData(queryKey, updated)
      void queryClient.invalidateQueries({ queryKey: ["scheduled_tasks"] })
    }
  })
  const destroy = useMutation({
    mutationFn: (task: RepositoryScheduledTask) => deleteRepositoryScheduledTask(payload.repository.id, task.id),
    onSuccess: (updated) => {
      setNotice(updated.message || null)
      queryClient.setQueryData(queryKey, updated)
      void queryClient.invalidateQueries({ queryKey: ["scheduled_tasks"] })
    }
  })

  return (
    <>
      <div className="flex flex-wrap items-center justify-between gap-3">
        <SectionHeading>{t("scheduled_tasks.heading")}</SectionHeading>
        <Link className={buttonClasses("primary")} to={`${prefix}/repositories/${payload.repository.id}/scheduled_tasks/new`}>{t("scheduled_tasks.new_task")}</Link>
      </div>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {toggle.isError ? <PanelMessage tone="error">{errorMessage(toggle.error, t("scheduled_tasks.error_update"))}</PanelMessage> : null}
      {destroy.isError ? <PanelMessage tone="error">{errorMessage(destroy.error, t("scheduled_tasks.error_delete"))}</PanelMessage> : null}

      {payload.tasks.length === 0 ? (
        <section className="rounded border border-dashed border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 p-8 text-center text-sm text-gray-500 dark:text-gray-400">
          {t("scheduled_tasks.no_tasks")}
        </section>
      ) : (
        <section>
          <DataTable.Root>
            <DataTable.Header>
              <DataTable.Row>
                <DataTable.HeadCell>{t("scheduled_tasks.name")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("scheduled_tasks.schedule")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("scheduled_tasks.next_window")}</DataTable.HeadCell>
                <DataTable.HeadCell>{t("scheduled_tasks.state")}</DataTable.HeadCell>
                <DataTable.HeadCell align="right">{t("scheduled_tasks.actions")}</DataTable.HeadCell>
              </DataTable.Row>
            </DataTable.Header>
            <DataTable.Body>
              {payload.tasks.map((task) => (
                <DataTable.Row key={task.id}>
                  <DataTable.Cell>
                    <Link className="font-medium text-brand dark:text-brand-emphasis underline hover:no-underline" to={`${prefix}/scheduled_tasks/${task.id}`}>{task.name}</Link>
                    <div className="mt-1 max-w-xl truncate text-xs text-gray-500 dark:text-gray-400">{task.prompt}</div>
                  </DataTable.Cell>
                  <DataTable.Cell className="font-mono text-gray-700 dark:text-gray-300">{task.schedule_label || t("scheduled_tasks.none")}</DataTable.Cell>
                  <DataTable.Cell className="text-gray-700 dark:text-gray-300">
                    {task.next_fire_at
                      ? <span title={toRomanDate(task.next_fire_at)}><RelativeTimestamp value={task.next_fire_at} /></span>
                      : t("scheduled_tasks.none")}
                  </DataTable.Cell>
                  <DataTable.Cell><StatePill state={task.state} /></DataTable.Cell>
                  <DataTable.Cell>
                    <div className="flex justify-end gap-2">
                      <Button
                        disabled={toggle.isPending}
                        onClick={() => toggle.mutate({ task, enabled: !task.active })}
                        variant="secondary"
                      >
                        {task.active ? t("scheduled_tasks.disable") : t("scheduled_tasks.enable")}
                      </Button>
                      <button
                        className="rounded border border-red-200 dark:border-red-800 px-3 py-1 text-sm text-red-700 dark:text-red-300 hover:bg-red-50 dark:hover:bg-red-950/50 disabled:cursor-not-allowed disabled:text-red-300 dark:disabled:text-red-500"
                        disabled={destroy.isPending}
                        onClick={async () => {
                          if (await confirm({ message: t("scheduled_tasks.confirm_delete"), destructive: true })) destroy.mutate(task)
                        }}
                        type="button"
                      >
                        {t("scheduled_tasks.delete")}
                      </button>
                    </div>
                  </DataTable.Cell>
                </DataTable.Row>
              ))}
            </DataTable.Body>
          </DataTable.Root>
        </section>
      )}
      {dialog}
    </>
  )
}

function StatePill({ state }: { state: string }) {
  const styles: Record<string, string> = {
    scheduled: "bg-green-100 dark:bg-green-950/40 text-green-700 dark:text-green-300",
    paused: "bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-400",
    auto_paused: "bg-amber-100 dark:bg-amber-950/40 text-amber-700 dark:text-amber-300",
    fired: "bg-info/10 text-info"
  }
  return <span className={`inline-block rounded px-2 py-0.5 text-xs font-medium ${styles[state] || "bg-gray-100 dark:bg-gray-800 text-gray-700 dark:text-gray-300"}`}>{state}</span>
}

function RepositoryScheduledTasksError({ error }: { error: Error }) {
  const { t } = useT("settings")
  return <PanelMessage tone="error">{errorMessage(error, t("scheduled_tasks.error_load"))}</PanelMessage>
}

