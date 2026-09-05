import { useLocation } from "react-router-dom"

import { CronTemplateDetailRoute, CronTemplateFormRoute, CronTemplatesIndex } from "./CronTemplates"
import { RepositoryScheduledTasksRoute } from "./RepositoryScheduledTasks"
import { ScheduledTaskDetailRoute, ScheduledTaskFormRoute, ScheduledTasksIndex } from "./ScheduledTasks"

// Single entry point for every page this plugin owns.
//
// The plugin sidebar-page loader resolves one component per registered path
// set and renders it without props, so the `mode="new" | "edit"` distinction
// that core's route table used to pass has to come from the URL instead.
export default function ScheduledTasksPage() {
  const location = useLocation()
  const path = location.pathname.replace(/^\/app-shell/, "") || "/"

  if (path.startsWith("/repositories/")) {
    return path.endsWith("/new") ? <ScheduledTaskFormRoute mode="new" /> : <RepositoryScheduledTasksRoute />
  }

  if (path.startsWith("/cron_templates")) {
    if (path === "/cron_templates") return <CronTemplatesIndex />
    if (path === "/cron_templates/new") return <CronTemplateFormRoute mode="new" />
    return path.endsWith("/edit") ? <CronTemplateFormRoute mode="edit" /> : <CronTemplateDetailRoute />
  }

  if (path === "/scheduled_tasks") return <ScheduledTasksIndex />
  if (path === "/scheduled_tasks/new") return <ScheduledTaskFormRoute mode="new" />
  return path.endsWith("/edit") ? <ScheduledTaskFormRoute mode="edit" /> : <ScheduledTaskDetailRoute />
}
