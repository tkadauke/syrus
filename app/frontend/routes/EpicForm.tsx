import { routePrefix, withRoutePrefix } from "../lib/routing"
import { inputClass } from "../lib/formClasses"
import { useMutation, useQuery } from "@tanstack/react-query"
import type { FormEvent, MouseEvent, ReactNode } from "react"
import { useEffect, useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import {
  createEpic,
  fetchEditEpicForm,
  fetchNewEpicForm,
  type EpicFormPayload,
  type EpicInput,
  updateEpic
} from "../api/epics"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"

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

export function EpicForm({ mode, payload, prefix }: { mode: "new" | "edit"; payload: EpicFormPayload; prefix: string }) {
  const { t } = useT("epics")
  const navigate = useNavigate()
  const [values, setValues] = useState<EpicInput>(() => inputFromPayload(payload))
  const save = useMutation({
    mutationFn: (options: { start: boolean }) => {
      if (mode === "new") return createEpic(values, { start: options.start })
      return updateEpic(Number(payload.epic.id), values)
    },
    onSuccess: (saved) => {
      navigate(withRoutePrefix(saved.redirect_to, prefix))
    }
  })

  useEffect(() => {
    setValues(inputFromPayload(payload))
  }, [payload])

  // The form's default submission (Enter key included) is always a plain
  // create/save. "Create Epic & Start Implementing" is deliberately NOT a
  // submit button so implicit form submission can never create-and-start.
  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    save.mutate({ start: false })
  }

  function createAndStart(event: MouseEvent<HTMLButtonElement>) {
    const formElement = event.currentTarget.form
    if (formElement && !formElement.reportValidity()) return

    save.mutate({ start: true })
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

        <Field label={t("epic_dependency_policy_label")}>
          {values.epic_dependency_policy === "nonlinear" ? (
            <>
              <select className={inputClass()} disabled value="nonlinear">
                <option value="nonlinear">{t("epic_dependency_policy_nonlinear")}</option>
              </select>
              <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
                {t("epic_dependency_policy_nonlinear_legacy_hint")}
              </p>
            </>
          ) : (
            <>
              <select
                className={inputClass()}
                onChange={(event) => setValues({ ...values, epic_dependency_policy: event.target.value as import("../api/epics").EpicDependencyPolicy })}
                value={values.epic_dependency_policy}
              >
                <option value="linear">{t("epic_dependency_policy_linear")}</option>
              </select>
              <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
                {t("epic_dependency_policy_linear_hint")}
              </p>
            </>
          )}
        </Field>

        <div className="flex flex-wrap items-center gap-3">
          {mode === "new" ? (
            <button
              className="rounded bg-blue-600 px-3.5 py-2.5 text-sm font-medium text-white hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-blue-300"
              disabled={save.isPending}
              onClick={createAndStart}
              type="button"
            >
              {save.isPending ? t("saving") : t("create_and_start")}
            </button>
          ) : null}
          <button
            className={mode === "new"
              ? "rounded border border-gray-300 bg-white px-3.5 py-2.5 text-sm font-medium text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:opacity-50 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-200 dark:hover:bg-gray-800"
              : "rounded bg-blue-600 px-3.5 py-2.5 text-sm font-medium text-white hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-blue-300"}
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

function inputFromPayload(payload: EpicFormPayload): EpicInput {
  return {
    title: payload.epic.title,
    description: payload.epic.description,
    repository_id: payload.epic.repository_id ? String(payload.epic.repository_id) : "",
    github_issue_url: payload.epic.github_issue_url,
    epic_dependency_policy: payload.epic.epic_dependency_policy
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
