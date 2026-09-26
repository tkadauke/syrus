import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useState } from "react"
import { useLocation, useNavigate } from "react-router-dom"
import {
  createAdminInvitation,
  fetchAdminInvitations,
  revokeAdminInvitation,
  type AdminInvitation,
  type AdminInvitationsPayload
} from "../api/adminInvitations"
import { AdminEventLogTable, type AdminEventLogTableColumn } from "../components/AdminEventLogPanel"
import { AdminFiltersLayout } from "../components/AdminFiltersLayout"
import { Button } from "../components/Button"
import { CopyIcon } from "../components/CopyableSlug"
import { FilterBar } from "../components/FilterBar"
import { Input } from "../components/Input"
import { NoticeToast } from "../components/NoticeToast"
import { Page } from "../components/ui"
import { useCopyToClipboard } from "../hooks/useCopyToClipboard"
import { usePageTitle } from "../hooks/usePageTitle"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"

const queryKey = ["admin", "invitations"] as const

export function AdminInvitations() {
  const { t } = useT("admin")
  usePageTitle(t("page_title_invitations"))
  const location = useLocation()
  const navigate = useNavigate()
  const [notice, setNotice] = useState<string | null>(null)
  const invitations = useQuery({
    queryKey: [...queryKey, location.search],
    queryFn: () => fetchAdminInvitations(location.search)
  })

  return (
    <Page.Root aria-label={t("aria_invitations")} gutter="responsive" size="wide">
      <Page.Header className="block border-b border-border pb-4">
        <Page.HeadingGroup>
          <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("section_label")}</p>
          <Page.Title className="mt-1">{t("invitations.heading")}</Page.Title>
        </Page.HeadingGroup>
      </Page.Header>

      <CreateInvitationForm onNotice={setNotice} />
      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />

      {invitations.isPending ? <PanelMessage>{t("invitations.loading")}</PanelMessage> : null}
      {invitations.isError ? <InvitationsError error={invitations.error} /> : null}
      {invitations.isSuccess ? (
        <AdminFiltersLayout
          description={<p className="max-w-prose text-sm text-gray-600 dark:text-gray-300">{t("invitations.description")}</p>}
          filterBar={
            <FilterBar
              filter={invitations.data.filter}
              filterSchema={invitations.data.filter_schema}
              legacyFilterKeys={["email"]}
              pathname={location.pathname}
              search={location.search}
            />
          }
        >
          <InvitationsTable
            invitations={invitations.data.invitations}
            onNavigate={(params) => navigate(`${location.pathname}?${params.toString()}`)}
            onNotice={setNotice}
            payload={invitations.data}
            search={location.search}
          />
        </AdminFiltersLayout>
      ) : null}
    </Page.Root>
  )
}

function CreateInvitationForm({ onNotice }: { onNotice: (message: string | null) => void }) {
  const { t } = useT("admin")
  const queryClient = useQueryClient()
  const [emailAddress, setEmailAddress] = useState("")
  const create = useMutation({
    mutationFn: () => createAdminInvitation(emailAddress),
    onSuccess: (payload) => {
      void queryClient.invalidateQueries({ queryKey })
      setEmailAddress("")
      onNotice(payload.message || t("invitations.invitation_created"))
    }
  })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    create.mutate()
  }

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
      <h2 className="text-sm font-semibold uppercase text-gray-500 dark:text-gray-400">{t("invitations.new_section")}</h2>
      <form className="mt-4 flex flex-col gap-3 sm:flex-row sm:items-end" onSubmit={submit}>
        <label className="flex-1 text-sm font-medium text-gray-700 dark:text-gray-200">
          {t("invitations.email_label")}
          <Input autoComplete="off" className="mt-1" onChange={(event) => setEmailAddress(event.target.value)} required type="email" value={emailAddress} />
        </label>
        <Button disabled={create.isPending} type="submit">
          {create.isPending ? t("invitations.generating") : t("invitations.generate")}
        </Button>
      </form>
      {create.isError ? (
        <p className="mt-3 text-sm text-red-700 dark:text-red-300" role="alert">
          {errorMessage(create.error, t("invitations.error_create"))}
        </p>
      ) : null}
    </section>
  )
}

function InvitationsTable({
  invitations,
  onNavigate,
  onNotice,
  payload,
  search
}: {
  invitations: AdminInvitation[]
  onNavigate: (params: URLSearchParams) => void
  onNotice: (message: string | null) => void
  payload: AdminInvitationsPayload
  search: string
}) {
  const { t } = useT("admin")
  if (invitations.length === 0) return <PanelMessage>{t("invitations.no_pending")}</PanelMessage>

  const columns: Array<AdminEventLogTableColumn<AdminInvitation>> = [
    {
      key: "email",
      header: t("invitations.col_email"),
      required: true,
      sort: "email",
      className: "whitespace-nowrap text-gray-900 dark:text-gray-100",
      render: (invitation) => invitation.email_address
    },
    {
      key: "share_url",
      header: t("invitations.col_share_url"),
      className: "min-w-[34rem] whitespace-nowrap font-mono text-xs",
      render: (invitation) => <InvitationShareUrl invitation={invitation} onNotice={onNotice} />
    },
    {
      key: "expires",
      header: t("invitations.col_expires"),
      sort: "expires_at",
      className: "whitespace-nowrap text-gray-600 dark:text-gray-300",
      render: (invitation) => <RelativeTimestamp value={invitation.expires_at} />
    },
    {
      key: "invited_by",
      header: t("invitations.col_invited_by"),
      sort: "inviter",
      className: "whitespace-nowrap text-gray-600 dark:text-gray-300",
      render: (invitation) => invitation.invited_by_email_address
    },
    {
      key: "created",
      header: t("invitations.col_created"),
      sort: "created_at",
      className: "whitespace-nowrap text-gray-600 dark:text-gray-300",
      render: (invitation) => <RelativeTimestamp value={invitation.created_at} />
    },
    {
      key: "actions",
      header: <span className="sr-only">{t("invitations.col_actions")}</span>,
      label: t("invitations.col_actions"),
      required: true,
      pin: "end",
      className: "whitespace-nowrap text-right",
      render: (invitation) => <InvitationActions invitation={invitation} onNotice={onNotice} />
    }
  ]

  return (
    <AdminEventLogTable
      columns={columns}
      defaultSort={payload.sort}
      getRowKey={(invitation) => invitation.id}
      onNavigate={onNavigate}
      panel={invitationsTablePanel(t, payload, onNavigate, search)}
      rows={invitations}
      search={search}
      storageKey="syrus.admin.invitations.visible_columns"
      tableClassName="min-w-[72rem] table-auto divide-y divide-border text-sm"
    />
  )
}

function InvitationShareUrl({ invitation, onNotice }: { invitation: AdminInvitation; onNotice: (message: string | null) => void }) {
  const { t } = useT("admin")
  const { copied, copy } = useCopyToClipboard()

  function copyUrl() {
    copy(invitation.share_url)
    onNotice(t("invitations.link_copied"))
  }

  return (
    <button
      aria-label={`Copy signup link for ${invitation.email_address}`}
      className="group inline-flex items-center gap-1 whitespace-nowrap text-left text-brand dark:text-brand-emphasis underline hover:no-underline cursor-copy"
      onClick={copyUrl}
      type="button"
    >
      <span>{invitation.share_url}</span>
      <CopyIcon
        className={`h-3.5 w-3.5 shrink-0 no-underline ${copied ? "text-green-600 dark:text-green-300" : "text-gray-400 group-hover:text-gray-600 dark:text-gray-500 dark:group-hover:text-gray-300"}`}
      />
    </button>
  )
}

function InvitationActions({ invitation, onNotice }: { invitation: AdminInvitation; onNotice: (message: string | null) => void }) {
  const { t } = useT("admin")
  const queryClient = useQueryClient()
  const [confirming, setConfirming] = useState(false)
  const revoke = useMutation({
    mutationFn: () => revokeAdminInvitation(invitation.id),
    onSuccess: (payload: AdminInvitationsPayload) => {
      void queryClient.invalidateQueries({ queryKey })
      onNotice(payload.message || t("invitations.revoke_confirm"))
    },
    onSettled: () => setConfirming(false)
  })

  return (
    <>
      {confirming ? (
        <span className="inline-flex items-center gap-2 text-sm">
          <span className="text-gray-700 dark:text-gray-200">{t("invitations.revoke_confirm")}</span>
          <button
            className="font-medium text-red-600 dark:text-red-300 underline hover:no-underline disabled:cursor-not-allowed disabled:text-red-300"
            disabled={revoke.isPending}
            onClick={() => {
              onNotice(null)
              revoke.mutate()
            }}
            type="button"
          >
            {revoke.isPending ? t("invitations.revoking") : t("invitations.revoke_yes")}
          </button>
          <button
            className="text-gray-500 dark:text-gray-400 underline hover:no-underline disabled:cursor-not-allowed"
            disabled={revoke.isPending}
            onClick={() => setConfirming(false)}
            type="button"
          >
            {t("invitations.cancel")}
          </button>
        </span>
      ) : (
        <button
          className="text-sm text-red-600 dark:text-red-300 underline hover:no-underline"
          onClick={() => {
            onNotice(null)
            setConfirming(true)
          }}
          type="button"
        >
          {t("invitations.revoke")}
        </button>
      )}
      {revoke.isError ? (
        <div className="mt-1 text-xs text-red-700 dark:text-red-300" role="alert">
          {errorMessage(revoke.error, t("invitations.error_revoke"))}
        </div>
      ) : null}
    </>
  )
}

function invitationsTablePanel(
  t: (key: string, options?: Record<string, number>) => string,
  payload: AdminInvitationsPayload,
  onNavigate: (params: URLSearchParams) => void,
  search: string
) {
  return {
    meta: t("invitations.pending"),
    pagination: {
      ariaLabel: t("invitations.pagination_aria"),
      label: t("invitations.page_of", { page: payload.pagination.page, total: payload.pagination.total_pages }),
      nextLabel: t("invitations.next"),
      onNavigate,
      pagination: payload.pagination,
      previousLabel: t("invitations.previous"),
      search
    },
    summary: t("invitations.showing", { first: payload.pagination.first_item, last: payload.pagination.last_item, total: payload.pagination.total })
  }
}

function InvitationsError({ error }: { error: Error }) {
  const { t } = useT("admin")
  return <PanelMessage tone="error">{errorMessage(error, t("invitations.error_load"))}</PanelMessage>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`p-4 text-sm ${tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-600 dark:text-gray-300"}`}>{children}</div>
}
