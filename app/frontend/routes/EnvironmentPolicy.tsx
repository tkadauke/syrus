import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useEffect, useState, type FormEvent } from "react"
import { fetchEnvironmentPolicy, updateEnvironmentPolicy } from "../api/environmentPolicy"
import { Button } from "../components/Button"
import { NoticeToast } from "../components/NoticeToast"
import { PageHeading, SectionHeading } from "../components/Heading"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"

const queryKey = ["admin", "environment_policy"] as const

export function EnvironmentPolicy() {
  const { t } = useT("admin")
  const queryClient = useQueryClient()
  const query = useQuery({ queryKey, queryFn: fetchEnvironmentPolicy })
  const [text, setText] = useState("")
  const [notice, setNotice] = useState<string | null>(null)
  useEffect(() => { if (query.data) setText(JSON.stringify(query.data.policy, null, 2)) }, [query.data])
  const save = useMutation({
    mutationFn: () => updateEnvironmentPolicy(JSON.parse(text) as Record<string, unknown>),
    onSuccess: (data) => { queryClient.setQueryData(queryKey, data); setNotice(data.message || t("environment_policy.updated")) }
  })
  const submit = (event: FormEvent) => { event.preventDefault(); setNotice(null); save.mutate() }

  return <main aria-label={t("aria_environment_policy")} className="mx-auto max-w-6xl space-y-6 p-6">
    <header className="border-b border-border pb-4"><p className="text-xs font-medium uppercase text-text-secondary">{t("section_label")}</p><PageHeading className="mt-1">{t("environment_policy.heading")}</PageHeading></header>
    <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
    {query.isPending ? <p>{t("environment_policy.loading")}</p> : null}
    {query.isError ? <p className="text-danger" role="alert">{errorMessage(query.error, t("environment_policy.error_load"))}</p> : null}
    {query.data ? <>
      <section className="rounded border border-border bg-surface p-4"><SectionHeading>{t("environment_policy.registry_heading")}</SectionHeading>
        <p className="mt-2 text-sm text-text-secondary">{query.data.registry.configured ? `${query.data.registry.url}/${query.data.registry.repository_prefix}` : t("environment_policy.registry_unconfigured")}</p>
        <p className="mt-1 text-xs text-text-secondary">{t("environment_policy.registry_secret_help")}</p>
      </section>
      <form className="rounded border border-border bg-surface p-4" onSubmit={submit}><SectionHeading>{t("environment_policy.policy_heading")}</SectionHeading>
        <p className="mt-1 text-sm text-text-secondary">{t("environment_policy.policy_help")}</p>
        <textarea aria-label={t("environment_policy.policy_json_label")} className="mt-3 min-h-96 w-full rounded border border-border bg-background p-3 font-mono text-sm" onChange={(event) => setText(event.target.value)} spellCheck={false} value={text} />
        <div className="mt-3"><Button disabled={save.isPending} type="submit">{save.isPending ? t("environment_policy.saving") : t("environment_policy.save")}</Button></div>
        {save.isError ? <p className="mt-2 text-sm text-danger" role="alert">{errorMessage(save.error, t("environment_policy.error_update"))}</p> : null}
      </form>
    </> : null}
  </main>
}
