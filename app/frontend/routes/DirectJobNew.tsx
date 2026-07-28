import { routePrefix, withRoutePrefix } from "../lib/routing"
import { inputClass } from "../lib/formClasses"
import { useMutation, useQuery } from "@tanstack/react-query"
import type { DragEvent, FormEvent, ReactNode } from "react"
import { useEffect, useMemo, useRef, useState } from "react"
import { Link, useLocation, useNavigate } from "react-router-dom"
import { useT } from "../hooks/useT"
import { NoticeToast } from "../components/NoticeToast"
import { OnboardingEmptyState, useSetupStatus } from "../components/OnboardingEmptyState"
import {
  createDirectJob,
  fetchDirectJobForm,
  type DirectJobFormPayload,
  type DirectJobPromptTemplate
} from "../api/directJobs"
import { errorMessage } from "../lib/errorMessage"

type DirectJobFormState = {
  repositoryId: string
  agentProvider: string
  title: string
  prompt: string
  priority: string
  createMore: boolean
  googleDocUrl: string
}

export function DirectJobNewRoute() {
  const { t } = useT("jobs")
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const form = useQuery({
    queryKey: ["direct_jobs", "new", location.search],
    queryFn: () => fetchDirectJobForm(location.search)
  })

  return (
    <main aria-label={t("aria_new_direct_job")} className="mx-auto max-w-4xl space-y-6 p-6">
      <header>
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("direct_job_title")}</h1>
        <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">{t("direct_job_description")}</p>
      </header>

      {form.isPending ? <PanelMessage>{t("direct_job_loading")}</PanelMessage> : null}
      {form.isError ? <PanelMessage tone="error">{errorMessage(form.error, t("direct_job_load_error"))}</PanelMessage> : null}
      {form.isSuccess ? <DirectJobForm payload={form.data} prefix={prefix} /> : null}
    </main>
  )
}

function DirectJobForm({ payload, prefix }: { payload: DirectJobFormPayload; prefix: string }) {
  const navigate = useNavigate()
  const { t } = useT("jobs")
  const setupStatus = useSetupStatus()
  const promptRef = useRef<HTMLTextAreaElement>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [files, setFiles] = useState<File[]>([])
  const [values, setValues] = useState<DirectJobFormState>(() => initialValues(payload))
  const [appliedTemplate, setAppliedTemplate] = useState<DirectJobPromptTemplate | null>(null)
  const selectedRepository = useMemo(
    () => payload.repositories.find((repository) => String(repository.id) === values.repositoryId) || null,
    [payload.repositories, values.repositoryId]
  )
  const save = useMutation({
    mutationFn: () => createDirectJob({ ...values, files }),
    onSuccess: (created) => {
      if (!created.create_more) {
        navigate(withRoutePrefix(created.redirect_to, prefix))
        return
      }

      setNotice(created.message || t("direct_job_created"))
      setFiles([])
      if (fileInputRef.current) fileInputRef.current.value = ""
      setValues((current) => ({
        ...current,
        title: "",
        prompt: "",
        priority: "medium",
        createMore: true,
        googleDocUrl: ""
      }))
    }
  })

  useEffect(() => {
    setValues(initialValues(payload))
    setFiles([])
    setNotice(null)
    if (fileInputRef.current) fileInputRef.current.value = ""
  }, [payload])

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setNotice(null)
    save.mutate()
  }

  function applyTemplate(template: DirectJobPromptTemplate) {
    const hasManualTitle = values.title.trim() !== "" && values.title !== (appliedTemplate?.name ?? "")
    const hasManualPrompt = values.prompt.trim() !== "" && values.prompt !== (appliedTemplate?.prompt ?? "")

    if ((hasManualTitle || hasManualPrompt) && !window.confirm(t("form_template_confirm"))) {
      return
    }

    setAppliedTemplate(template)
    setValues((current) => ({
      ...current,
      title: template.name,
      prompt: template.prompt
    }))
    window.requestAnimationFrame(() => promptRef.current?.focus())
  }

  function dropFiles(event: DragEvent<HTMLDivElement>) {
    event.preventDefault()
    if (event.dataTransfer.files.length > 0) {
      setFiles(Array.from(event.dataTransfer.files))
    }
  }

  if (payload.repositories.length === 0) {
    return (
      <OnboardingEmptyState
        fallbackActionPath={payload.new_repository_path}
        fallbackActionText={t("direct_job_no_repositories_action")}
        fallbackDescription={t("direct_job_no_repositories_description")}
        fallbackTitle={t("direct_job_no_repositories_title")}
        prefix={prefix}
        setupStatus={setupStatus}
      />
    )
  }

  return (
    <form className="space-y-5" onSubmit={submit}>
      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {save.isError ? <PanelMessage tone="error">{errorMessage(save.error, t("direct_job_create_error"))}</PanelMessage> : null}

      <section className="space-y-4 rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
        <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("form_section_target")}</h2>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label={t("form_repository_label")}>
            <select
              className={inputClass()}
              name="repository_id"
              onChange={(event) => setValues({ ...values, repositoryId: event.target.value })}
              required
              value={values.repositoryId}
            >
              <option value="">{t("form_repository_placeholder")}</option>
              {payload.repositories.map((repository) => (
                <option key={repository.id} value={repository.id}>{repository.slug}</option>
              ))}
            </select>
          </Field>

          {payload.configured_agent_providers.length > 1 ? (
            <Field label={t("form_agent_label")}>
              <select
                className={inputClass()}
                name="agent_provider"
                onChange={(event) => setValues({ ...values, agentProvider: event.target.value })}
                value={values.agentProvider}
              >
                <option value="">{t("form_agent_repository_default")} ({selectedRepository?.default_agent_provider_label || "default"})</option>
                {payload.configured_agent_providers.map((provider) => (
                  <option key={provider.value} value={provider.value}>{provider.label}</option>
                ))}
              </select>
            </Field>
          ) : null}
        </div>
      </section>

      {payload.prompt_templates.length > 0 ? (
        <section className="space-y-3">
          <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("form_section_templates")}</h2>
          <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
            {payload.prompt_templates.map((template) => (
              <button
                className="rounded border border-gray-200 bg-white px-3 py-2.5 text-left hover:border-blue-300 hover:bg-blue-50 focus:outline-none focus:ring-2 focus:ring-blue-500 dark:border-gray-700 dark:bg-gray-900 dark:hover:border-blue-700 dark:hover:bg-blue-950/40"
                key={template.id}
                onClick={() => applyTemplate(template)}
                type="button"
              >
                <span className="block text-sm font-medium text-gray-900 dark:text-gray-100">{template.name}</span>
                <span className="mt-0.5 block text-xs leading-snug text-gray-500 dark:text-gray-400">{template.description}</span>
              </button>
            ))}
          </div>
        </section>
      ) : null}

      <section className="space-y-4 rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
        <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("form_section_prompt")}</h2>
        <Field label={t("form_title_label")}>
          <input
            className={inputClass()}
            name="title"
            onChange={(event) => setValues({ ...values, title: event.target.value })}
            placeholder={t("form_title_placeholder")}
            type="text"
            value={values.title}
          />
        </Field>
        <Field label={t("form_section_prompt")}>
          <textarea
            className={`${inputClass()} font-mono`}
            name="prompt"
            onChange={(event) => setValues({ ...values, prompt: event.target.value })}
            placeholder={t("form_prompt_placeholder")}
            ref={promptRef}
            required
            rows={10}
            value={values.prompt}
          />
        </Field>
        <Field label={t("form_priority_label")}>
          <select
            className={inputClass()}
            name="priority"
            onChange={(event) => setValues({ ...values, priority: event.target.value })}
            value={values.priority}
          >
            {payload.priorities.map((priority) => (
              <option key={priority.value} value={priority.value}>
                {priority.label} {priority.description ? `- ${priority.description}` : ""}
              </option>
            ))}
          </select>
        </Field>
      </section>

      <section className="space-y-4 rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
        <div>
          <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("section_attachments")}</h2>
          <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{t("form_attachments_description")}</p>
        </div>

        <div
          className="cursor-pointer rounded border border-dashed border-gray-300 px-4 py-6 text-center text-sm text-gray-500 transition-colors hover:border-blue-300 hover:bg-blue-50 dark:border-gray-700 dark:text-gray-400 dark:hover:border-blue-700 dark:hover:bg-blue-950/40"
          onClick={() => fileInputRef.current?.click()}
          onDragOver={(event) => event.preventDefault()}
          onDrop={dropFiles}
          onKeyDown={(event) => {
            if (event.key === "Enter" || event.key === " ") {
              event.preventDefault()
              fileInputRef.current?.click()
            }
          }}
          role="button"
          tabIndex={0}
        >
          <div className="font-medium text-gray-700 dark:text-gray-300">{t("form_drop_files")}</div>
          <div className="mt-1 text-xs">{t("form_file_types_hint")}</div>
        </div>
        <input
          accept={payload.accepted_file_content_types.join(",")}
          className="hidden"
          multiple
          onChange={(event) => setFiles(Array.from(event.currentTarget.files || []))}
          ref={fileInputRef}
          type="file"
        />
        <div className="flex flex-wrap items-center gap-3">
          <button
            className="rounded border border-gray-300 px-3 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:text-gray-300 dark:hover:bg-gray-800"
            onClick={() => fileInputRef.current?.click()}
            type="button"
          >
            {t("form_choose_files")}
          </button>
          {files.length > 0 ? <span className="text-sm text-gray-600 dark:text-gray-400">{files.map((file) => file.name).join(", ")}</span> : null}
        </div>

        <Field label={t("attachment_google_doc_label")}>
          <input
            className={inputClass()}
            name="job_attachment_google_doc_url"
            onChange={(event) => setValues({ ...values, googleDocUrl: event.target.value })}
            placeholder={t("attachment_google_doc_placeholder")}
            type="url"
            value={values.googleDocUrl}
          />
        </Field>
      </section>

      <label className="flex items-center gap-2 text-sm font-medium text-gray-700 dark:text-gray-300">
        <input
          checked={values.createMore}
          className="h-4 w-4 rounded border-gray-300 text-blue-600 focus:ring-blue-500 dark:border-gray-700 dark:bg-gray-950"
          name="create_more"
          onChange={(event) => setValues({ ...values, createMore: event.target.checked })}
          type="checkbox"
        />
        {t("form_create_more")}
      </label>

      <div className="flex items-center gap-3">
        <button
          className="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-blue-300"
          disabled={save.isPending}
          type="submit"
        >
          {save.isPending ? t("form_creating") : t("form_create_job")}
        </button>
        <Link className="text-sm text-gray-600 underline hover:no-underline dark:text-gray-400 dark:hover:text-gray-200" to={withRoutePrefix(payload.dashboard_jobs_path, prefix)}>{t("cancel")}</Link>
      </div>
    </form>
  )
}

function initialValues(payload: DirectJobFormPayload): DirectJobFormState {
  return {
    repositoryId: payload.selected_repository_id || "",
    agentProvider: payload.selected_agent_provider || "",
    title: "",
    prompt: "",
    priority: "medium",
    createMore: payload.create_more,
    googleDocUrl: ""
  }
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
      {label}
      <div className="mt-1">{children}</div>
    </label>
  )
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" | "success" }) {
  const colors = {
    error: "border-red-200 bg-red-50 text-red-700 dark:border-red-900/70 dark:bg-red-950/40 dark:text-red-200",
    success: "border-green-200 bg-green-50 text-green-700 dark:border-green-900/70 dark:bg-green-950/40 dark:text-green-200",
    muted: "border-gray-200 bg-white text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

