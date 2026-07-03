import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useState } from "react"
import {
  createAdminInvitation,
  fetchAdminInvitations,
  revokeAdminInvitation,
  type AdminInvitation,
  type AdminInvitationsPayload
} from "../api/adminInvitations"
import { ApiError } from "../api/client"
import { NoticeToast } from "../components/NoticeToast"

const queryKey = ["admin", "invitations"] as const

export function AdminInvitations() {
  const [notice, setNotice] = useState<string | null>(null)
  const invitations = useQuery({
    queryKey,
    queryFn: fetchAdminInvitations
  })

  return (
    <main aria-label="Admin invitations" className="mx-auto max-w-6xl space-y-6 p-6">
      <header className="border-b border-gray-200 dark:border-gray-700 pb-4">
        <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">Admin</p>
        <h1 className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">Invitations</h1>
        <p className="mt-2 max-w-prose text-sm text-gray-600 dark:text-gray-300">
          Generate one-time signup links. Default expiry is 7 days, and invitations work even when open signups are disabled.
        </p>
      </header>

      <CreateInvitationForm onNotice={setNotice} />
      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />

      <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
        <div className="border-b border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-800 px-4 py-2 text-sm font-semibold text-gray-700 dark:text-gray-200">Pending invitations</div>
        {invitations.isPending ? <PanelMessage>Loading invitations...</PanelMessage> : null}
        {invitations.isError ? <InvitationsError error={invitations.error} /> : null}
        {invitations.isSuccess ? <InvitationsTable invitations={invitations.data.invitations} onNotice={setNotice} /> : null}
      </section>
    </main>
  )
}

function CreateInvitationForm({ onNotice }: { onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const [emailAddress, setEmailAddress] = useState("")
  const create = useMutation({
    mutationFn: () => createAdminInvitation(emailAddress),
    onSuccess: (payload) => {
      queryClient.setQueryData(queryKey, payload)
      setEmailAddress("")
      onNotice(payload.message || "Invitation created.")
    }
  })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    create.mutate()
  }

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
      <h2 className="text-sm font-semibold uppercase text-gray-500 dark:text-gray-400">New invitation</h2>
      <form className="mt-4 flex flex-col gap-3 sm:flex-row sm:items-end" onSubmit={submit}>
        <label className="flex-1 text-sm font-medium text-gray-700 dark:text-gray-200">
          Email address
          <input
            autoComplete="off"
            className="mt-1 block w-full rounded border border-gray-300 dark:border-gray-600 px-3 py-2 text-sm shadow-sm focus:outline-blue-600"
            onChange={(event) => setEmailAddress(event.target.value)}
            required
            type="email"
            value={emailAddress}
          />
        </label>
        <button
          className="rounded bg-blue-600 dark:bg-blue-500 px-3.5 py-2 text-sm font-medium text-white hover:bg-blue-500 dark:hover:bg-blue-400 disabled:cursor-not-allowed disabled:bg-blue-300 dark:disabled:bg-blue-900"
          disabled={create.isPending}
          type="submit"
        >
          {create.isPending ? "Generating..." : "Generate"}
        </button>
      </form>
      {create.isError ? <p className="mt-3 text-sm text-red-700 dark:text-red-300" role="alert">{errorMessage(create.error, "Unable to create invitation.")}</p> : null}
    </section>
  )
}

function InvitationsTable({ invitations, onNotice }: { invitations: AdminInvitation[]; onNotice: (message: string | null) => void }) {
  if (invitations.length === 0) return <PanelMessage>No pending invitations.</PanelMessage>

  return (
    <div className="overflow-x-auto">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
        <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">Email</th>
            <th className="px-4 py-2">Share URL</th>
            <th className="px-4 py-2">Expires</th>
            <th className="px-4 py-2">Invited by</th>
            <th className="px-4 py-2"><span className="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {invitations.map((invitation) => (
            <InvitationRow invitation={invitation} key={invitation.id} onNotice={onNotice} />
          ))}
        </tbody>
      </table>
    </div>
  )
}

function InvitationRow({ invitation, onNotice }: { invitation: AdminInvitation; onNotice: (message: string | null) => void }) {
  const queryClient = useQueryClient()
  const [confirming, setConfirming] = useState(false)
  const revoke = useMutation({
    mutationFn: () => revokeAdminInvitation(invitation.id),
    onSuccess: (payload: AdminInvitationsPayload) => {
      queryClient.setQueryData(queryKey, payload)
      onNotice(payload.message || "Invitation revoked.")
    },
    onSettled: () => setConfirming(false)
  })

  return (
    <tr>
      <td className="whitespace-nowrap px-4 py-3 text-gray-900 dark:text-gray-100">{invitation.email_address}</td>
      <td className="max-w-xl px-4 py-3 font-mono text-xs">
        <a className="break-all text-blue-600 dark:text-blue-300 underline hover:no-underline" href={invitation.share_url}>{invitation.share_url}</a>
      </td>
      <td className="whitespace-nowrap px-4 py-3 text-gray-600 dark:text-gray-300">{formatDate(invitation.expires_at)}</td>
      <td className="whitespace-nowrap px-4 py-3 text-gray-600 dark:text-gray-300">{invitation.invited_by_email_address}</td>
      <td className="whitespace-nowrap px-4 py-3 text-right">
        {confirming ? (
          <span className="inline-flex items-center gap-2 text-sm">
            <span className="text-gray-700 dark:text-gray-200">Revoke this invitation?</span>
            <button
              className="font-medium text-red-600 dark:text-red-300 underline hover:no-underline disabled:cursor-not-allowed disabled:text-red-300"
              disabled={revoke.isPending}
              onClick={() => {
                onNotice(null)
                revoke.mutate()
              }}
              type="button"
            >
              {revoke.isPending ? "Revoking..." : "Yes, revoke"}
            </button>
            <button
              className="text-gray-500 dark:text-gray-400 underline hover:no-underline disabled:cursor-not-allowed"
              disabled={revoke.isPending}
              onClick={() => setConfirming(false)}
              type="button"
            >
              Cancel
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
            Revoke
          </button>
        )}
        {revoke.isError ? <div className="mt-1 text-xs text-red-700 dark:text-red-300" role="alert">{errorMessage(revoke.error, "Unable to revoke invitation.")}</div> : null}
      </td>
    </tr>
  )
}

function InvitationsError({ error }: { error: Error }) {
  return <PanelMessage tone="error">{errorMessage(error, "Unable to load invitations.")}</PanelMessage>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`p-4 text-sm ${tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-600 dark:text-gray-300"}`}>{children}</div>
}

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}

function formatDate(value: string) {
  return new Date(value).toLocaleString()
}
