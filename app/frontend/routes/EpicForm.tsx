import { useMutation, useQuery } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useEffect, useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import { ApiError } from "../api/client"
import {
  createEpic,
  fetchEditEpicForm,
  fetchNewEpicForm,
  type EpicFormPayload,
  type EpicInput,
  updateEpic
} from "../api/epics"
import { useT } from "../hooks/useT"

export function EpicFormRoute({ mode }: { mode: "new" | "edit" }) {
  const { t } = useT("epics")
  const params = useParams()
  const location = useLocation()
  const id = params.id || ""
  const prefix = routePrefix(location.pathname)
  const form = useQuery({
    queryKey: ["epics", mode, id],
    queryFn: () => mode === "new" ? fetchNewEpicForm() : fetchEditEpicForm(id),
    enabled: mode === "new" || id.length > 0
  })

  return (
    <main aria-label={mode === "new" ? t("new_epic") : t("edit_epic")} className="mx-auto max-w-2xl space-y-6 p-6">
      {form.isPending ? <PanelMessage>{t("form_loading")}</PanelMessage> : null}
      {form.isError ? <PanelMessage tone="error">{errorMessage(form.error, t("form_load_error"))}</PanelMessage> : null}
      {form.isSuccess ? <EpicForm mode={mode} payload={form.data} prefix={prefix} /> : null}
    </main>
  )
}

function EpicForm({ mode, payload, prefix }: { mode: "new" | "edit"; payload: EpicFormPayload; prefix: string }) {
  const { t } = useT("epics")
  const navigate = useNavigate()
  const [values, setValues] = useState<EpicInput>(() => inputFromPayload(payload))
  const save = useMutation({
    mutationFn: () => {
      if (mode === "new") return createEpic(values)
      return updateEpic(Number(payload.epic.id), values)
    },
    onSuccess: (saved) => {
      navigate(withRoutePrefix(saved.redirect_to, prefix))
    }
  })

  useEffect(() => {
    setValues(inputFromPayload(payload))
  }, [payload])

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    save.mutate()
  }

  return (
    <>
      <header className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">{mode === "new" ? t("new_epic") : t("edit_epic")}</h1>
        {mode === "edit" && payload.epic.epic_path ? <Link className="text-sm text-blue-600 underline hover:no-underline" to={withRoutePrefix(payload.epic.epic_path, prefix)}>{t("back_to_epic")}</Link> : null}
      </header>

      {save.isError ? <PanelMessage tone="error">{errorMessage(save.error, t("save_error"))}</PanelMessage> : null}

      <form className="space-y-5" onSubmit={submit}>
        <Field label={t("form_title")}>
          <input
            className={inputClass()}
            onChange={(event) => setValues({ ...values, title: event.target.value })}
            required
            type="text"
            value={values.title}
          />
        </Field>

        <Field label={t("description")}>
          <textarea
            className={inputClass()}
            onChange={(event) => setValues({ ...values, description: event.target.value })}
            rows={8}
            value={values.description}
          />
        </Field>

        <Field label={t("form_repository")}>
          <select
            className={inputClass()}
            onChange={(event) => setValues({ ...values, repository_id: event.target.value })}
            required
            value={values.repository_id}
          >
            <option value="">{t("select_repository")}</option>
            {payload.repositories.map((repository) => (
              <option key={repository.id} value={repository.id}>{repository.slug}</option>
            ))}
          </select>
        </Field>

        <Field label={t("github_issue_url")}>
          <input
            className={`${inputClass()} font-mono`}
            onChange={(event) => setValues({ ...values, github_issue_url: event.target.value })}
            type="text"
            value={values.github_issue_url}
          />
        </Field>

        <div className="flex items-center gap-3">
          <button
            className="rounded bg-blue-600 px-3.5 py-2.5 text-sm font-medium text-white hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-blue-300"
            disabled={save.isPending}
            type="submit"
          >
            {save.isPending ? t("saving") : mode === "new" ? t("create") : t("save")}
          </button>
          <Link className="text-sm text-gray-600 hover:text-gray-900 dark:text-gray-400 dark:hover:text-gray-200" to={withRoutePrefix(mode === "new" ? payload.dashboard_epics_path : payload.epic.epic_path || payload.dashboard_epics_path, prefix)}>{t("cancel")}</Link>
        </div>
      </form>
    </>
  )
}

function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}

function inputFromPayload(payload: EpicFormPayload): EpicInput {
  return {
    title: payload.epic.title,
    description: payload.epic.description,
    repository_id: payload.epic.repository_id ? String(payload.epic.repository_id) : "",
    github_issue_url: payload.epic.github_issue_url
  }
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
      {label}
      <div className="mt-2">{children}</div>
    </label>
  )
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  const colors = {
    error: "border-red-200 bg-red-50 text-red-700 dark:border-red-900/70 dark:bg-red-950/40 dark:text-red-200",
    muted: "border-gray-200 bg-white text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

function inputClass() {
  return "block w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 shadow-sm focus:outline-blue-600 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100 dark:placeholder:text-gray-500"
}

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}
