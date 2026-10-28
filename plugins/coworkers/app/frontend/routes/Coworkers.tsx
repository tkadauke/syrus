import { useMutation, useQuery } from "@tanstack/react-query"
import { FormEvent, useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import { Avatar } from "@app/components/Avatar"
import { AvatarPicker } from "@app/components/AvatarPicker"
import { ColorPicker } from "@app/components/ColorPicker"
import { Checkbox } from "@app/components/Checkbox"
import { Input } from "@app/components/Input"
import { Textarea } from "@app/components/Textarea"
import { PageHeading } from "@app/components/Heading"
import { PanelMessage } from "@app/components/PanelMessage"
import { Page } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { withRoutePrefix } from "@app/lib/routing"
import { createCoworker, createSideChat, fetchCoworker, fetchCoworkers, testCoworkerRemote, type CoworkerSummary } from "../api/coworkers"

export default function CoworkersRoute() {
  const { id } = useParams()
  const location = useLocation()
  if (location.pathname.endsWith("/new")) return <NewCoworker />
  if (id) return <CoworkerPage id={id} />
  return <CoworkerList />
}

function usePrefix() {
  return useLocation().pathname.startsWith("/app-shell") ? "/app-shell" : ""
}

function CoworkerList() {
  const { t } = useT("coworkers")
  const prefix = usePrefix()
  const query = useQuery({ queryKey: ["coworkers"], queryFn: fetchCoworkers })
  return (
    <Page.Root gutter="responsive" size="wide">
      <Page.Header className="flex items-center justify-between">
        <PageHeading>{t("title")}</PageHeading>
        <Link className="rounded bg-brand px-3 py-2 text-sm font-medium text-white" to={`${prefix}/coworkers/new`}>
          {t("new.action")}
        </Link>
      </Page.Header>
      {query.isPending ? <PanelMessage>{t("loading")}</PanelMessage> : null}
      {query.isError ? <PanelMessage>{t("error")}</PanelMessage> : null}
      {query.data ? (
        <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
          <CoworkerCard coworker={query.data.syrus} prefix={prefix} />
          {query.data.coworkers.map((coworker) => (
            <CoworkerCard coworker={coworker} prefix={prefix} key={coworker.id} />
          ))}
        </div>
      ) : null}
    </Page.Root>
  )
}

function CoworkerCard({ coworker, prefix }: { coworker: CoworkerSummary; prefix: string }) {
  const { t } = useT("coworkers")
  return (
    <Link className="rounded border border-border bg-surface p-4 hover:border-brand" style={{ borderLeftWidth: 4 }} to={withRoutePrefix(coworker.path, prefix)}>
      <div className="flex gap-3">
        <Avatar avatarUrl={coworker.avatar_url} avatarKey={coworker.avatar_key} colorKey={coworker.color_key} name={coworker.name} />
        <div>
          <div className="font-semibold text-text-primary">{coworker.name}</div>
          <div className="text-sm text-text-secondary">@{coworker.handle}</div>
          <div className="mt-2 text-sm text-text-secondary">{coworker.role_summary}</div>
          {coworker.built_in ? <span className="mt-2 inline-block rounded bg-surface-subtle px-2 py-0.5 text-xs">{t("built_in")}</span> : null}
        </div>
      </div>
    </Link>
  )
}

function NewCoworker() {
  const { t } = useT("coworkers")
  const navigate = useNavigate()
  const prefix = usePrefix()
  const [color, setColor] = useState("coral-soft")
  const [avatar, setAvatar] = useState<string | null>(null)
  const [remote, setRemote] = useState("")
  const mutation = useMutation({ mutationFn: createCoworker, onSuccess: (data) => navigate(withRoutePrefix(data.redirect_to, prefix)) })
  const remoteTest = useMutation({ mutationFn: () => testCoworkerRemote(remote) })
  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const form = new FormData(event.currentTarget)
    form.set("color_key", color)
    if (avatar) form.set("avatar_key", avatar)
    mutation.mutate(form)
  }
  return (
    <Page.Root gutter="responsive" size="narrow">
      <Page.Header>
        <Link className="text-sm text-brand" to={`${prefix}/coworkers`}>
          {t("title")}
        </Link>
        <PageHeading>{t("new.title")}</PageHeading>
      </Page.Header>
      <form className="space-y-5 rounded border border-border bg-surface p-5" onSubmit={submit}>
        <Field label={t("fields.name")} name="name" required />
        <Field label={t("fields.handle")} name="handle" required pattern="[a-z0-9_-]{3,32}" />
        <Field label={t("fields.model")} name="chat_model" />
        <label className="block text-sm font-medium">
          {t("fields.remote")}
          <Input
            className="mt-1"
            name="workspace_repo"
            onChange={(event) => setRemote(event.target.value)}
            placeholder="https://github.com/owner/repository"
            required
            type="url"
          />
        </label>
        <div>
          <button
            className="rounded border border-border px-3 py-2 text-sm"
            disabled={!remote || remoteTest.isPending}
            onClick={() => remoteTest.mutate()}
            type="button"
          >
            {t("new.test_push")}
          </button>
          {remoteTest.isSuccess ? <span className="ml-2 text-sm text-success">{t("new.push_ok")}</span> : null}
          {remoteTest.isError ? <span className="ml-2 text-sm text-danger">{remoteTest.error.message}</span> : null}
        </div>
        <div>
          <label className="mb-2 block text-sm font-medium">{t("fields.color")}</label>
          <ColorPicker ariaLabel={t("fields.color")} mode="light" value={color} onChange={setColor} />
        </div>
        <div>
          <label className="mb-2 block text-sm font-medium">{t("fields.avatar")}</label>
          <AvatarPicker ariaLabel={t("fields.avatar")} value={avatar} onChange={setAvatar} />
          <Input accept="image/*" className="mt-3" name="avatar" type="file" />
        </div>
        <fieldset>
          <legend className="mb-2 text-sm font-medium">{t("fields.grants")}</legend>
          {["chat.message_owner", "workspace.files", "workspace.shell", "chats.read_shared", "syrus.read_jobs"].map((grant) => (
            <Checkbox className="mb-2" defaultChecked key={grant} label={grant} name="grants[]" value={grant} />
          ))}
        </fieldset>
        <label className="block text-sm font-medium">
          {t("fields.about")}
          <Textarea className="mt-1 min-h-28" name="about" />
        </label>
        {mutation.isError ? <PanelMessage>{mutation.error.message}</PanelMessage> : null}
        <button className="rounded bg-brand px-4 py-2 font-medium text-white" disabled={mutation.isPending}>
          {t("new.create")}
        </button>
      </form>
    </Page.Root>
  )
}

function Field({ label, ...props }: { label: string; name: string; required?: boolean; pattern?: string; type?: string; placeholder?: string }) {
  return (
    <label className="block text-sm font-medium">
      {label}
      <Input {...props} className="mt-1" />
    </label>
  )
}

function CoworkerPage({ id }: { id: string }) {
  const { t } = useT("coworkers")
  const prefix = usePrefix()
  const navigate = useNavigate()
  const [tab, setTab] = useState("chat")
  const query = useQuery({ queryKey: ["coworkers", id], queryFn: () => fetchCoworker(id), enabled: id !== "syrus" })
  const sideChat = useMutation({ mutationFn: () => createSideChat(Number(id)), onSuccess: (data) => navigate(withRoutePrefix(data.chat_path, prefix)) })
  if (id === "syrus") return <SyrusPage tab={tab} setTab={setTab} />
  if (query.isPending) return <PanelMessage>{t("loading")}</PanelMessage>
  if (!query.data) return <PanelMessage>{t("error")}</PanelMessage>
  const coworker = query.data.coworker
  return (
    <Page.Root gutter="responsive" size="wide">
      <Page.Header>
        <Link className="text-sm text-brand" to={`${prefix}/coworkers`}>
          {t("title")}
        </Link>
        <div className="mt-3 flex items-center gap-3">
          <Avatar avatarUrl={coworker.avatar_url} avatarKey={coworker.avatar_key} colorKey={coworker.color_key} name={coworker.name} size="large" />
          <div>
            <PageHeading>{coworker.name}</PageHeading>
            <div className="text-text-secondary">@{coworker.handle}</div>
          </div>
        </div>
      </Page.Header>
      <Tabs active={tab} setActive={setTab} labels={["chat", "profile", "capabilities", "schedule", "memory", "workspace", "activity"]} />
      {tab === "chat" ? (
        <section className="space-y-3">
          <button className="rounded bg-brand px-3 py-2 text-sm text-white" onClick={() => sideChat.mutate()}>
            {t("detail.new_side_chat")}
          </button>
          {coworker.chats.map((chat) => (
            <Link className="block rounded border border-border bg-surface p-3 text-brand" key={chat.id} to={withRoutePrefix(chat.path, prefix)}>
              {chat.role === "main" ? t("detail.main_chat") : chat.title}
            </Link>
          ))}
        </section>
      ) : null}
      {tab === "profile" ? (
        <section className="space-y-4 rounded border border-border bg-surface p-5">
          <dl>
            <dt>{t("fields.model")}</dt>
            <dd>{coworker.effective_model || t("detail.account_default")}</dd>
            <dt>{t("fields.remote")}</dt>
            <dd>{coworker.workspace_repo}</dd>
          </dl>
          <h2 className="font-semibold">SOUL.md</h2>
          <div className="whitespace-pre-wrap rounded bg-surface-subtle p-4 text-sm">{coworker.soul || t("detail.soul_unavailable")}</div>
        </section>
      ) : null}
      {!["chat", "profile"].includes(tab) ? <PanelMessage>{t("coming_later")}</PanelMessage> : null}
    </Page.Root>
  )
}

function Tabs({ active, setActive, labels }: { active: string; setActive: (value: string) => void; labels: string[] }) {
  const { t } = useT("coworkers")
  return (
    <div className="mb-5 flex gap-5 overflow-x-auto border-b border-border">
      {labels.map((label) => (
        <button
          className={`pb-2 text-sm ${active === label ? "border-b-2 border-brand font-semibold" : "text-text-secondary"}`}
          key={label}
          onClick={() => setActive(label)}
        >
          {t(`tabs.${label}`)}
        </button>
      ))}
    </div>
  )
}
function SyrusPage({ tab, setTab }: { tab: string; setTab: (value: string) => void }) {
  const { t } = useT("coworkers")
  const prefix = usePrefix()
  return (
    <Page.Root gutter="responsive" size="wide">
      <Page.Header>
        <PageHeading>Syrus</PageHeading>
        <p className="text-text-secondary">{t("built_in")}</p>
      </Page.Header>
      <Tabs active={tab} setActive={setTab} labels={["chats", "profile", "capabilities", "schedule", "memory"]} />
      {tab === "profile" ? (
        <PanelMessage>{t("detail.account_default")}</PanelMessage>
      ) : tab === "capabilities" ? (
        <PanelMessage>{t("detail.engineer_capabilities")}</PanelMessage>
      ) : tab === "chats" ? (
        <Link className="text-brand underline" to={`${prefix}/chats/search`}>
          {t("tabs.chats")}
        </Link>
      ) : tab === "schedule" ? (
        <Link className="text-brand underline" to={`${prefix}/scheduled_tasks`}>
          {t("tabs.schedule")}
        </Link>
      ) : tab === "memory" ? (
        <Link className="text-brand underline" to={`${prefix}/memories`}>
          {t("tabs.memory")}
        </Link>
      ) : (
        <PanelMessage>{t("detail.existing_link")}</PanelMessage>
      )}
    </Page.Root>
  )
}
