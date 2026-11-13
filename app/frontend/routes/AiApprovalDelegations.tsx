import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useState } from "react"
import { Link, useLocation } from "react-router-dom"
import { createApprovalDelegation, fetchApprovalDelegations, revokeApprovalDelegation, type InheritedPermission } from "../api/permissions"
import { Input } from "../components/Input"
import { SectionHeading } from "../components/Heading"
import { PanelMessage } from "../components/PanelMessage"
import { Select } from "../components/Select"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"
import { routePrefix, withRoutePrefix } from "../lib/routing"

const queryKey = ["approval_delegations"] as const

export function AiApprovalDelegations({ descriptors }: { descriptors: InheritedPermission[] }) {
  const { t } = useT("settings")
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const queryClient = useQueryClient()
  const query = useQuery({ queryKey, queryFn: fetchApprovalDelegations })
  const refresh = () => queryClient.invalidateQueries({ queryKey })
  const [providerKey, setProviderKey] = useState("")
  const [capability, setCapability] = useState("")
  const [resourceType, setResourceType] = useState("")
  const [scopeText, setScopeText] = useState("{}")
  const [scopeError, setScopeError] = useState(false)
  const create = useMutation({
    mutationFn: (scope: Record<string, unknown>) =>
      createApprovalDelegation({
        provider_key: providerKey || query.data?.providers[0]?.provider_key,
        capability: capability || capabilities[0],
        resource_type: resourceType,
        resource_scope: scope
      }),
    onSuccess: () => {
      setResourceType("")
      setScopeText("{}")
      void refresh()
    }
  })
  const revoke = useMutation({ mutationFn: revokeApprovalDelegation, onSuccess: refresh })
  const data = query.data
  const capabilities = [...new Set(descriptors.map((item) => item.capability))]
  const capabilityName = (identifier: string) =>
    descriptors.find((item) => withoutVersion(item.capability) === withoutVersion(identifier))?.presentation.capability_name || t("permissions.unknown")
  const effectNames = (effects: string[]) => effects.map((effect) => t(`permissions.effect_names.${effect}`)).join(", ")

  const submit = () => {
    try {
      const parsed = JSON.parse(scopeText)
      if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("scope")
      setScopeError(false)
      create.mutate(parsed as Record<string, unknown>)
    } catch {
      setScopeError(true)
    }
  }

  return (
    <section aria-label={t("permissions.ai.title")} className="min-w-0 space-y-4 rounded-xl border border-border bg-surface-raised p-4 sm:p-5">
      <div>
        <SectionHeading>{t("permissions.ai.title")}</SectionHeading>
        <p className="mt-1 text-sm text-text-secondary">{t("permissions.ai.help")}</p>
      </div>
      {query.isError ? <PanelMessage tone="error">{t("permissions.ai.load_error")}</PanelMessage> : null}
      {create.isError ? <PanelMessage tone="error">{errorMessage(create.error, t("permissions.ai.create_error"))}</PanelMessage> : null}
      {revoke.isError ? <PanelMessage tone="error">{errorMessage(revoke.error, t("permissions.ai.revoke_error"))}</PanelMessage> : null}
      {data && !data.enabled ? <p className="text-sm text-text-muted">{t("permissions.ai.disabled")}</p> : null}

      {data?.providers.map((provider) => (
        <article className="min-w-0 overflow-x-auto rounded-lg border border-border p-3 text-sm" key={provider.provider_key}>
          <h3 className="font-medium text-text-primary">{provider.display_name}</h3>
          <p className="mt-1 text-text-secondary">
            <span className="font-medium">{t("permissions.ai.privacy")}:</span> {provider.data_sharing}
          </p>
          <p className="mt-1 text-text-secondary">
            <span className="font-medium">{t("permissions.ai.guidance")}:</span> {provider.default_guidance}
          </p>
        </article>
      ))}

      {data ? (
        <div className="text-sm text-text-secondary">
          <p>
            {t("permissions.ai.human_only", {
              effects: effectNames(data.human_only.effects),
              capabilities: data.human_only.capabilities.map(capabilityName).join(", ")
            })}
          </p>
          <code className="block text-xs text-text-muted">{data.human_only.capabilities.join(", ")}</code>
        </div>
      ) : null}

      {data ? (
        <div className="space-y-4 border-t border-border pt-4">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div>
              <h3 className="text-sm font-medium text-text-primary">{t("permissions.ai.plugins_title")}</h3>
              <p className="mt-1 text-sm text-text-secondary">{t("permissions.ai.plugins_help")}</p>
            </div>
            {data.can_manage_plugins ? (
              <Link className="text-sm font-medium text-brand hover:underline" to={withRoutePrefix("/admin/plugins", prefix)}>
                {t("permissions.ai.manage_plugins")}
              </Link>
            ) : null}
          </div>
          <PluginGroup installed plugins={(data.plugins || []).filter((plugin) => plugin.installed)} />
          <PluginGroup installed={false} plugins={(data.plugins || []).filter((plugin) => !plugin.installed)} />
        </div>
      ) : null}

      <div className="space-y-2">
        <h3 className="text-sm font-medium text-text-primary">{t("permissions.ai.delegations")}</h3>
        {data?.delegations.map((delegation) => (
          <article className="min-w-0 overflow-x-auto rounded-lg border border-border p-3" key={delegation.id}>
            <div className="flex min-w-max flex-wrap items-start justify-between gap-3 sm:min-w-full">
              <div className="text-sm">
                <p className="font-medium text-text-primary">
                  {delegation.provider_name} · {capabilityName(delegation.capability)}
                  <code className="block text-xs font-normal text-text-muted">{delegation.capability}</code>
                </p>
                <p className="text-text-secondary">
                  {t(`permissions.ai.status.${delegation.status}`)} · {delegation.resource_type} · {JSON.stringify(delegation.resource_scope)}
                </p>
                <p className="text-xs text-text-muted">{t("permissions.ai.excluded", { effects: effectNames(delegation.excluded_effects) })}</p>
              </div>
              {delegation.status !== "revoked" ? (
                <button className="text-sm font-medium text-danger" disabled={revoke.isPending} onClick={() => revoke.mutate(delegation.id)} type="button">
                  {t("permissions.ai.revoke")}
                </button>
              ) : null}
            </div>
          </article>
        ))}
        {data && data.delegations.length === 0 ? <p className="text-sm text-text-muted">{t("permissions.ai.no_delegations")}</p> : null}
      </div>

      {data?.enabled ? (
        <form
          className="grid gap-3 md:grid-cols-2"
          onSubmit={(event) => {
            event.preventDefault()
            submit()
          }}
        >
          <label className="text-sm">
            {t("permissions.ai.provider")}
            <Select value={providerKey || data.providers[0].provider_key} onChange={(event) => setProviderKey(event.target.value)}>
              {data.providers.map((provider) => (
                <option key={provider.provider_key} value={provider.provider_key}>
                  {provider.display_name}
                </option>
              ))}
            </Select>
          </label>
          <label className="text-sm">
            {t("permissions.capability")}
            <Select value={capability || capabilities[0]} onChange={(event) => setCapability(event.target.value)}>
              {capabilities.map((item) => (
                <option key={item} value={item}>
                  {capabilityName(item)}
                </option>
              ))}
            </Select>
          </label>
          <label className="text-sm">
            {t("permissions.ai.resource_type")}
            <Input value={resourceType} onChange={(event) => setResourceType(event.target.value)} required />
          </label>
          <label className="text-sm">
            {t("permissions.ai.scope")}
            <Input value={scopeText} onChange={(event) => setScopeText(event.target.value)} aria-invalid={scopeError} />
          </label>
          {scopeError ? <p className="text-sm text-danger md:col-span-2">{t("permissions.ai.scope_invalid")}</p> : null}
          <button className="rounded-md bg-brand px-3 py-2 text-sm font-medium text-white md:col-span-2" disabled={create.isPending} type="submit">
            {t("permissions.ai.delegate")}
          </button>
        </form>
      ) : null}

      <div className="space-y-2">
        <h3 className="text-sm font-medium text-text-primary">{t("permissions.ai.history")}</h3>
        {data?.history.map((entry) => (
          <p className="text-sm text-text-secondary" key={entry.id}>
            {t("permissions.ai.decision", { outcome: entry.outcome ?? "—", purpose: entry.purpose ?? t("permissions.unknown") })}
            {entry.rationale ? ` — ${entry.rationale}` : ""}
          </p>
        ))}
        {data && data.history.length === 0 ? <p className="text-sm text-text-muted">{t("permissions.ai.no_history")}</p> : null}
      </div>
    </section>
  )
}

function PluginGroup({ installed, plugins }: { installed: boolean; plugins: import("../api/permissions").ApprovalPlugin[] }) {
  const { t } = useT("settings")
  return (
    <section aria-label={t(installed ? "permissions.ai.installed_plugins" : "permissions.ai.available_plugins")} className="space-y-2">
      <h4 className="text-sm font-semibold text-text-primary">{t(installed ? "permissions.ai.installed_plugins" : "permissions.ai.available_plugins")}</h4>
      {plugins.map((plugin) => (
        <article className="min-w-0 rounded-lg border border-border p-3 text-sm" key={plugin.name}>
          <h5 className="font-medium text-text-primary">{plugin.display_name}</h5>
          <ContributionList label={t("permissions.ai.plugin_capabilities")} values={plugin.capabilities.map((capability) => capability.name)} />
          <ContributionList label={t("permissions.ai.plugin_tools")} values={plugin.tools} code />
        </article>
      ))}
      {plugins.length === 0 ? (
        <p className="text-sm text-text-muted">{t(installed ? "permissions.ai.no_installed_plugins" : "permissions.ai.no_available_plugins")}</p>
      ) : null}
    </section>
  )
}

function ContributionList({ label, values, code = false }: { label: string; values: string[]; code?: boolean }) {
  const { t } = useT("settings")
  return (
    <p className="mt-1 break-words text-text-secondary">
      <span className="font-medium">{label}:</span>{" "}
      {values.length
        ? values.map((value, index) => (
            <span key={value}>
              {index ? ", " : ""}
              {code ? <code>{value}</code> : value}
            </span>
          ))
        : t("permissions.ai.none")}
    </p>
  )
}

function withoutVersion(identifier: string) {
  return identifier.replace(/@v\d+$/, "")
}
