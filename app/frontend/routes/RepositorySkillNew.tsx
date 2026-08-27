import { routePrefix, withRoutePrefix } from "../lib/routing"
import { PageHeading, SectionHeading } from "../components/Heading"
import { inputClass } from "../lib/formClasses"
import { useMutation, useQuery } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useEffect, useState } from "react"
import { useLocation, useNavigate, useParams } from "react-router-dom"
import { useT } from "../hooks/useT"
import {
  createSkillJob,
  fetchRepositorySkills,
  type RepositorySkillsPayload,
  type SkillParameterField,
  type SkillSummary
} from "../api/skills"
import { errorMessage } from "../lib/errorMessage"
import { Button } from "../components/Button"
import { Checkbox } from "../components/Checkbox"
import { Input } from "../components/Input"
import { Select } from "../components/Select"

export function RepositorySkillNewRoute() {
  const { t } = useT("jobs")
  const location = useLocation()
  const params = useParams()
  const repositoryId = params.repositoryId || ""
  const prefix = routePrefix(location.pathname)
  const skills = useQuery({
    queryKey: ["repositories", repositoryId, "skills"],
    queryFn: () => fetchRepositorySkills(repositoryId),
    enabled: repositoryId.length > 0
  })

  return (
    <main aria-label={t("aria_new_skill_job")} className="mx-auto max-w-4xl space-y-6 p-6">
      <header>
        <PageHeading>{t("skill_job_title")}</PageHeading>
        <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">{t("skill_job_description")}</p>
      </header>

      {skills.isPending ? <PanelMessage>{t("skill_job_loading")}</PanelMessage> : null}
      {skills.isError ? <PanelMessage tone="error">{errorMessage(skills.error, t("skill_job_load_error"))}</PanelMessage> : null}
      {skills.isSuccess ? <SkillLaunchForm payload={skills.data} prefix={prefix} repositoryId={repositoryId} /> : null}
    </main>
  )
}

function SkillLaunchForm({
  payload,
  prefix,
  repositoryId
}: {
  payload: RepositorySkillsPayload
  prefix: string
  repositoryId: string
}) {
  const navigate = useNavigate()
  const { t } = useT("jobs")
  const [selectedName, setSelectedName] = useState<string>(payload.skills[0]?.name || "")
  const [args, setArgs] = useState<Record<string, string | boolean>>({})
  const [agentProvider, setAgentProvider] = useState<string>("")
  const [priority, setPriority] = useState<string>("medium")

  const selectedSkill = payload.skills.find((skill) => skill.name === selectedName) || null

  useEffect(() => {
    setArgs(initialArgs(selectedSkill))
  }, [selectedSkill])

  const create = useMutation({
    mutationFn: () => {
      if (!selectedSkill) throw new Error("no skill selected")
      return createSkillJob(repositoryId, { name: selectedSkill.name, args, agentProvider, priority })
    },
    onSuccess: (created) => {
      navigate(withRoutePrefix(created.redirect_to, prefix))
    }
  })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    create.mutate()
  }

  if (payload.skills.length === 0) {
    return <PanelMessage>{t("skill_job_no_skills")}</PanelMessage>
  }

  return (
    <form className="space-y-5" onSubmit={submit}>
      {create.isError ? <PanelMessage tone="error">{errorMessage(create.error, t("skill_job_create_error"))}</PanelMessage> : null}

      <section className="space-y-3 rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
        <SectionHeading>{t("skill_job_section_pick")}</SectionHeading>
        <div className="space-y-2">
          {payload.skills.map((skill) => (
            <SkillOption
              key={skill.name}
              onSelect={() => setSelectedName(skill.name)}
              selected={skill.name === selectedName}
              skill={skill}
            />
          ))}
        </div>
      </section>

      {selectedSkill ? (
        <section className="space-y-4 rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
          <SectionHeading>{t("skill_job_section_parameters")}</SectionHeading>
          {selectedSkill.parameters.length === 0 ? (
            <p className="text-sm text-gray-500 dark:text-gray-400">{t("skill_job_no_parameters")}</p>
          ) : (
            selectedSkill.parameters.map((field) => (
              <SkillParameterInput
                field={field}
                key={field.key}
                onChange={(value) => setArgs((current) => ({ ...current, [field.key]: value }))}
                value={args[field.key]}
              />
            ))
          )}
        </section>
      ) : null}

      <section className="space-y-4 rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
        <SectionHeading>{t("skill_job_section_launch")}</SectionHeading>
        <div className="grid gap-4 sm:grid-cols-2">
          {payload.configured_agent_providers.length > 1 ? (
            <Field label={t("skill_job_agent_label")}>
              <Select onChange={(event) => setAgentProvider(event.target.value)} value={agentProvider}>
                <option value="">{t("skill_job_agent_repository_default")} ({payload.repository.default_agent_provider_label})</option>
                {payload.configured_agent_providers.map((provider) => (
                  <option key={provider.value} value={provider.value}>{provider.label}</option>
                ))}
              </Select>
            </Field>
          ) : null}
          <Field label={t("skill_job_priority_label")}>
            <Select onChange={(event) => setPriority(event.target.value)} value={priority}>
              {payload.priorities.map((value) => (
                <option key={value} value={value}>{value}</option>
              ))}
            </Select>
          </Field>
        </div>
        <Button
          disabled={!selectedSkill || create.isPending}
          type="submit"
          variant="primary"
        >
          {create.isPending ? t("skill_job_submitting") : t("skill_job_submit")}
        </Button>
      </section>
    </form>
  )
}

export function SkillOption({ skill, selected, onSelect }: { skill: SkillSummary; selected: boolean; onSelect: () => void }) {
  const { t } = useT("jobs")
  return (
    <label
      className={`block cursor-pointer rounded border p-3 text-sm ${
        selected
          ? "border-terracotta-400 bg-terracotta-50 dark:border-terracotta-700 dark:bg-terracotta-950/30"
          : "border-gray-200 hover:bg-gray-50 dark:border-gray-700 dark:hover:bg-gray-800"
      }`}
    >
      <div className="flex items-start gap-2">
        <input checked={selected} className="mt-1" name="skill_name" onChange={onSelect} type="radio" value={skill.name} />
        <div className="flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <span className="font-mono font-medium text-gray-900 dark:text-gray-100">{skill.name}</span>
            <SourceBadge shadowsBuiltIn={skill.shadows_built_in} source={skill.source} />
          </div>
          <p className="mt-0.5 text-gray-600 dark:text-gray-400">{skill.description}</p>
          {skill.shadows_built_in ? (
            <p className="mt-1 text-xs text-amber-700 dark:text-amber-400">{t("skill_job_shadows_built_in")}</p>
          ) : null}
          {skill.resolved_path ? (
            <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{t("skill_job_resolved_path", { path: skill.resolved_path })}</p>
          ) : null}
          {skill.resolved_class ? (
            <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{t("skill_job_resolved_class", { resolvedClass: skill.resolved_class })}</p>
          ) : null}
        </div>
      </div>
    </label>
  )
}

function SourceBadge({ source, shadowsBuiltIn }: { source: SkillSummary["source"]; shadowsBuiltIn: boolean }) {
  const { t } = useT("jobs")
  const isOverride = source === "repo_override"
  const label = isOverride ? t("skill_job_source_repo_override") : t("skill_job_source_built_in")
  const tone = shadowsBuiltIn
    ? "bg-amber-100 text-amber-700 dark:bg-amber-950/40 dark:text-amber-300"
    : isOverride
      ? "bg-blue-100 text-blue-700 dark:bg-blue-950/40 dark:text-blue-300"
      : "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-300"
  return <span className={`inline-block rounded px-2 py-0.5 text-xs font-medium ${tone}`}>{label}</span>
}

export function SkillParameterInput({
  field,
  value,
  onChange
}: {
  field: SkillParameterField
  value: string | boolean | undefined
  onChange: (value: string | boolean) => void
}) {
  if (field.type === "boolean") {
    return (
      <Checkbox
        checked={Boolean(value)}
        label={field.label}
        onChange={(event) => onChange(event.target.checked)}
      />
    )
  }

  if (field.type === "select") {
    return (
      <Field label={field.label}>
        <Select
          onChange={(event) => onChange(event.target.value)}
          required={field.required}
          value={typeof value === "string" ? value : ""}
        >
          <option value="">{field.label}</option>
          {(field.options || []).map((option) => (
            <option key={option} value={option}>{option}</option>
          ))}
        </Select>
      </Field>
    )
  }

  if (field.type === "text") {
    return (
      <Field label={field.label}>
        <textarea
          className={inputClass()}
          onChange={(event) => onChange(event.target.value)}
          required={field.required}
          rows={4}
          value={typeof value === "string" ? value : ""}
        />
      </Field>
    )
  }

  return (
    <Field label={field.label}>
      <Input
        onChange={(event) => onChange(event.target.value)}
        required={field.required}
        type={field.type === "integer" ? "number" : "text"}
        value={typeof value === "string" ? value : ""}
      />
    </Field>
  )
}

export function initialArgs(skill: SkillSummary | null): Record<string, string | boolean> {
  if (!skill) return {}
  return skill.parameters.reduce<Record<string, string | boolean>>((values, field) => {
    if (field.type === "boolean") {
      values[field.key] = Boolean(field.default)
    } else {
      values[field.key] = field.default == null ? "" : String(field.default)
    }
    return values
  }, {})
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
      {label}
      <div className="mt-1">{children}</div>
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
