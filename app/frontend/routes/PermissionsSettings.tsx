import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useMemo, useState } from "react"
import { Link } from "react-router-dom"
import { createPermissionRule, fetchPermissions, revokePermissionRule, type InheritedPermission } from "../api/permissions"
import { PageHeading, SectionHeading } from "../components/Heading"
import { Input } from "../components/Input"
import { PanelMessage } from "../components/PanelMessage"
import { Select } from "../components/Select"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"

const queryKey = ["permission_rules"] as const
const subjects = ["interactive_chat", "coding_chat", "local_chat"] as const

export function PermissionsSettingsRoute() {
  const { t } = useT("settings")
  usePageTitle(t("permissions.title"))
  const queryClient = useQueryClient()
  const query = useQuery({ queryKey, queryFn: fetchPermissions })
  const descriptors = query.data?.inherited ?? []
  const [subject, setSubject] = useState<(typeof subjects)[number]>("interactive_chat")
  const [descriptorKey, setDescriptorKey] = useState("")
  const [policy, setPolicy] = useState<"allow" | "deny">("allow")
  const [rationale, setRationale] = useState("")
  const selected = useMemo(() => descriptors.find((item) => keyFor(item) === descriptorKey) ?? descriptors[0], [descriptorKey, descriptors])
  const refresh = () => queryClient.invalidateQueries({ queryKey })
  const create = useMutation({
    mutationFn: () =>
      createPermissionRule({
        policy,
        role: roleFor(subject),
        subject_selector_type: subject,
        capability: selected.capability,
        operation: selected.operation,
        resource_scope: {},
        constraints: {},
        rationale
      }),
    onSuccess: () => {
      setRationale("")
      void refresh()
    }
  })
  const revoke = useMutation({ mutationFn: revokePermissionRule, onSuccess: refresh })

  return (
    <main aria-label={t("permissions.title")} className="mx-auto max-w-6xl space-y-6 p-6">
      <header>
        <PageHeading>{t("permissions.title")}</PageHeading>
        <p className="mt-1 text-sm text-text-secondary">{t("permissions.description")}</p>
        <Link className="mt-2 inline-block text-sm font-medium text-brand hover:underline" to="/dashboard">
          {t("permissions.approvals_link")}
        </Link>
      </header>

      {query.isError ? <PanelMessage tone="error">{t("permissions.load_error")}</PanelMessage> : null}

      <section className="rounded-xl border border-border bg-surface-raised p-5">
        <SectionHeading>{t("permissions.your_rules")}</SectionHeading>
        <p className="mt-1 text-sm text-text-secondary">{t("permissions.your_rules_help")}</p>
        <div className="mt-4 space-y-3">
          {(query.data?.rules ?? [])
            .filter((rule) => !rule.revoked_at)
            .map((rule) => (
              <article className="flex flex-col gap-3 rounded-lg border border-border p-4 sm:flex-row sm:items-center sm:justify-between" key={rule.id}>
                <div>
                  <p className="font-medium text-text-primary">
                    {rule.capability} · {rule.operation || t("permissions.all_operations")}
                  </p>
                  <p className="mt-1 text-sm text-text-secondary">
                    {t("permissions.rule_summary", { policy: rule.policy, subject: rule.subject_selector_type })}
                  </p>
                  <p className="mt-1 text-xs text-text-muted">
                    {t("permissions.owned_by", { owner: rule.owner.name })}
                    {rule.rationale ? ` · ${rule.rationale}` : ""}
                  </p>
                </div>
                {rule.editable ? (
                  <button
                    className="rounded-md border border-border px-3 py-1.5 text-sm font-medium text-danger hover:bg-danger/10"
                    disabled={revoke.isPending}
                    onClick={() => revoke.mutate(rule.id)}
                  >
                    {t("permissions.revoke")}
                  </button>
                ) : null}
              </article>
            ))}
          {query.data?.rules.filter((rule) => !rule.revoked_at).length === 0 ? <p className="text-sm text-text-muted">{t("permissions.no_rules")}</p> : null}
        </div>

        {selected ? (
          <form
            className="mt-5 grid gap-3 border-t border-border pt-5 md:grid-cols-2"
            onSubmit={(event) => {
              event.preventDefault()
              create.mutate()
            }}
          >
            <label className="text-sm font-medium text-text-primary">
              {t("permissions.subject")}
              <Select className="mt-1" onChange={(event) => setSubject(event.target.value as typeof subject)} value={subject}>
                {subjects.map((item) => (
                  <option key={item} value={item}>
                    {t(`permissions.subjects.${item}`)}
                  </option>
                ))}
              </Select>
            </label>
            <label className="text-sm font-medium text-text-primary">
              {t("permissions.capability")}
              <Select className="mt-1" onChange={(event) => setDescriptorKey(event.target.value)} value={descriptorKey || keyFor(selected)}>
                {descriptors.map((item) => (
                  <option key={keyFor(item)} value={keyFor(item)}>
                    {item.capability} · {item.operation}
                  </option>
                ))}
              </Select>
            </label>
            <label className="text-sm font-medium text-text-primary">
              {t("permissions.policy")}
              <Select className="mt-1" onChange={(event) => setPolicy(event.target.value as "allow" | "deny")} value={policy}>
                <option value="allow">{t("permissions.allow")}</option>
                <option value="deny">{t("permissions.deny")}</option>
              </Select>
            </label>
            <label className="text-sm font-medium text-text-primary">
              {t("permissions.rationale")}
              <Input className="mt-1" onChange={(event) => setRationale(event.target.value)} value={rationale} />
            </label>
            <button
              className="w-fit rounded-md bg-brand px-4 py-2 text-sm font-semibold text-on-brand disabled:opacity-50"
              disabled={create.isPending}
              type="submit"
            >
              {t("permissions.add_rule")}
            </button>
          </form>
        ) : null}
      </section>

      <section className="rounded-xl border border-border bg-surface-raised p-5">
        <SectionHeading>{t("permissions.inherited_policy")}</SectionHeading>
        <p className="mt-1 text-sm text-text-secondary">{t("permissions.inherited_help")}</p>
        <div className="mt-4 divide-y divide-border">
          {descriptors.map((item) => (
            <InheritedRow item={item} key={keyFor(item)} t={t} />
          ))}
        </div>
      </section>
    </main>
  )
}

function InheritedRow({ item, t }: { item: InheritedPermission; t: (key: string, options?: Record<string, unknown>) => string }) {
  const defaults = Object.entries(item.defaults)
    .map(([role, policy]) => `${role}: ${policy}`)
    .join(", ")
  return (
    <div className="py-3">
      <div className="flex items-center justify-between gap-3">
        <p className="font-medium text-text-primary">
          {item.capability} · {item.operation}
        </p>
        <span className="rounded-full bg-surface px-2 py-1 text-xs text-text-muted">{t("permissions.read_only")}</span>
      </div>
      <p className="mt-1 text-sm text-text-secondary">{defaults}</p>
      <p className="mt-1 text-xs text-text-muted">{t("permissions.decisive_explanation", { owner: item.owner.name })}</p>
    </div>
  )
}

function keyFor(item: InheritedPermission) {
  return `${item.capability}:${item.operation}`
}
function roleFor(subject: string) {
  return subject === "interactive_chat" ? "chat:planner" : subject === "coding_chat" ? "chat:coding" : "chat:local"
}
