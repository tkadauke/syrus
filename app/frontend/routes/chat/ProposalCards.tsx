import type { ChatQueryKey } from "./constants"
import { useMutation, useQuery, useQueryClient, type UseMutationResult } from "@tanstack/react-query"
import type { FormEvent, MouseEvent as ReactMouseEvent, ReactNode } from "react"
import { useCallback, useEffect, useState } from "react"
import { Link } from "react-router-dom"
import "@excalidraw/excalidraw/index.css"
import { confirmChatProposal, confirmPendingAction, rejectChatProposal, rejectPendingAction, searchChatEpics, searchChatJobs, searchChatProposals, updateChatProposal, type ChatEpicDependencySearchResult, type ChatJobDependencySearchResult, type ChatPendingAction, type ChatPendingActionInline, type ChatPayload, type ChatProposal, type ChatProposalChild, type ChatProposalChildDependency, type ChatProposalDependency, type ChatProposalSearchResult } from "../../api/chats"
import { fetchBootstrap } from "../../api/bootstrap"
import { CloseIcon } from "../../components/CloseIcon"
import { ConfirmationCard } from "../../components/ConfirmationCard"
import { StartEpicButton } from "../../components/StartEpicButton"
import { Markdown } from "../../lib/Markdown"
import { linkifySlugs } from "../../lib/linkifySlugs"
import { useT } from "../../hooks/useT"
import { errorMessage } from "../../lib/errorMessage"
import { appendSearch, primaryButton, secondaryButton, withRoutePrefix } from "./utils"
import { pendingActionBadgeLabel, pendingActionKey, pendingActionResourceTitle, pendingActionResourceUrl, pendingActionTerminalLabel } from "./pendingActionDisplay"
import type { DependencyPill, EditableProposal } from "./proposalDisplay"
import { PencilIcon } from "./icons"
import { editableChildProposal, initialProposalDependencyPills, proposalConfirmLabel } from "./proposalDisplay"




// Proposal / pending-action cards extracted from Chat.tsx: the proposal card and
// its edit modal, dependency pickers/strips/links, materialized-result footer,
// child-proposal rows, and the pending-action card. ProposalCard and
// PendingActionCard are the entry points the message stream renders. Depends only
// on leaf modules and shared UI imports; unused header imports were pruned.

function PillList({ values }: { values: string[] }) {
  return <div className="flex flex-wrap gap-1">{values.map((value) => <span className="rounded bg-gray-100 px-2 py-0.5 font-mono dark:bg-gray-800" key={value}>{value}</span>)}</div>
}

export function ProposalEditModal({ chatId, proposal, search, queryKey, onClose, onNotice }: { chatId: string | number; proposal: EditableProposal; search: string; queryKey: ChatQueryKey; onClose: () => void; onNotice: (message: string | null) => void }) {
  const { t } = useT("chat")
  const queryClient = useQueryClient()
  const [title, setTitle] = useState(proposal.title)
  const [body, setBody] = useState(proposal.body)
  const [activeTab, setActiveTab] = useState<"edit" | "preview">("edit")
  const [proposalDeps, setProposalDeps] = useState<DependencyPill[]>(initialProposalDependencyPills(proposal))
  const [jobDeps, setJobDeps] = useState<DependencyPill[]>((proposal.depends_on_job_ids || []).map((id) => ({ key: String(id), label: `JOB-${id}` })))
  const [epicDeps, setEpicDeps] = useState<DependencyPill[]>((proposal.depends_on_epic_ids || []).map((id) => ({ key: String(id), label: `EPIC-${id}` })))
  const [nonlinearDependencyOverride, setNonlinearDependencyOverride] = useState(Boolean(proposal.nonlinear_dependency_override))
  const [proposalQuery, setProposalQuery] = useState("")
  const [jobQuery, setJobQuery] = useState("")
  const [epicQuery, setEpicQuery] = useState("")
  const [proposalResults, setProposalResults] = useState<ChatProposalSearchResult[]>([])
  const [jobResults, setJobResults] = useState<ChatJobDependencySearchResult[]>([])
  const [epicResults, setEpicResults] = useState<ChatEpicDependencySearchResult[]>([])
  const searchProposals = useCallback((query: string, signal: AbortSignal) => searchChatProposals(chatId, query, proposal.id, { signal }), [chatId, proposal.id])
  const searchJobs = useCallback((query: string, signal: AbortSignal) => searchChatJobs(query, { signal }), [])
  const searchEpics = useCallback((query: string, signal: AbortSignal) => searchChatEpics(query, { signal }), [])

  const save = useMutation({
    mutationFn: () => updateChatProposal(appendSearch(proposal.app_update_path, search), {
      title: title.trim(),
      body,
      dependency_slugs: proposalDeps.map((dep) => dep.key),
      depends_on_job_ids: jobDeps.map((dep) => Number(dep.key)).filter((id) => Number.isFinite(id)),
      depends_on_epic_ids: epicDeps.map((dep) => Number(dep.key)).filter((id) => Number.isFinite(id)),
      nonlinear_dependency_override: nonlinearDependencyOverride
    }),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || "Proposal updated")
      onClose()
    }
  })

  useDebouncedDependencySearch(proposalQuery, searchProposals, setProposalResults)
  useDebouncedDependencySearch(jobQuery, searchJobs, setJobResults)
  useDebouncedDependencySearch(epicQuery, searchEpics, setEpicResults)

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (title.trim().length === 0) return
    save.mutate()
  }

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 px-3 py-6">
      <div className="max-h-full w-full max-w-5xl overflow-y-auto rounded-lg bg-white shadow-xl dark:bg-gray-950" role="dialog" aria-modal="true" aria-labelledby="proposal-edit-title">
        <form onSubmit={submit}>
          <div className="flex items-center justify-between border-b border-gray-200 px-5 py-4 dark:border-gray-800">
            <div>
              <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100" id="proposal-edit-title">{t("edit_proposal")}</h2>
              <p className="mt-0.5 font-mono text-xs text-gray-500 dark:text-gray-400">{proposal.slug}</p>
            </div>
            <button className="rounded p-1 text-gray-500 hover:bg-gray-100 hover:text-gray-700 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-200" onClick={onClose} type="button" aria-label={t("aria_close_proposal_editor")}>
              <CloseIcon className="h-4 w-4" />
            </button>
          </div>
          <div className="space-y-5 px-5 py-4">
            {save.isError ? <div className="rounded border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-200">{errorMessage(save.error, "Proposal update failed.")}</div> : null}
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-200">
              Title
              <input
                className="mt-1 w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100"
                onChange={(event) => setTitle(event.target.value)}
                required
                type="text"
                value={title}
              />
            </label>
            <div>
              <div className="mb-2 flex gap-2 sm:hidden">
                {(["edit", "preview"] as const).map((tab) => (
                  <button className={`rounded border px-3 py-1 text-sm ${activeTab === tab ? "border-blue-600 bg-blue-50 text-blue-700 dark:border-blue-500 dark:bg-blue-950 dark:text-blue-200" : "border-gray-300 text-gray-600 dark:border-gray-700 dark:text-gray-300"}`} key={tab} onClick={() => setActiveTab(tab)} type="button">
                    {tab === "edit" ? "Edit" : "Preview"}
                  </button>
                ))}
              </div>
              <div className="grid gap-3 sm:grid-cols-2">
                <label className={`${activeTab === "preview" ? "hidden sm:block" : "block"} text-sm font-medium text-gray-700 dark:text-gray-200`}>
                  Body
                  <textarea
                    className="mt-1 h-72 w-full resize-y rounded border border-gray-300 bg-white px-3 py-2 font-mono text-sm text-gray-900 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100"
                    onChange={(event) => setBody(event.target.value)}
                    value={body}
                  />
                </label>
                <div className={`${activeTab === "edit" ? "hidden sm:block" : "block"}`}>
                  <div className="text-sm font-medium text-gray-700 dark:text-gray-200">Preview</div>
                  <div className="mt-1 h-72 overflow-y-auto rounded border border-gray-200 bg-gray-50 px-3 py-2 dark:border-gray-800 dark:bg-gray-900">
                    <Markdown className="chat-prose text-sm text-gray-800 dark:text-gray-100" text={body} />
                  </div>
                </div>
              </div>
            </div>
            <div className="grid gap-4 lg:grid-cols-3">
              <DependencyPicker
                label="Proposal dependencies"
                placeholder={t("ph_search_proposals")}
                query={proposalQuery}
                results={proposalResults.map((result) => ({ key: result.slug, label: result.slug, detail: result.title }))}
                selected={proposalDeps}
                setQuery={setProposalQuery}
                setSelected={setProposalDeps}
              />
              <DependencyPicker
                label="Job dependencies"
                placeholder={t("ph_search_jobs")}
                query={jobQuery}
                results={jobResults.map((result) => ({ key: String(result.id), label: `JOB-${result.id}`, detail: result.issue_title || result.title || "" }))}
                selected={jobDeps}
                setQuery={setJobQuery}
                setSelected={setJobDeps}
              />
              <DependencyPicker
                label="Epic dependencies"
                placeholder={t("ph_search_epics")}
                query={epicQuery}
                results={epicResults.map((result) => ({ key: String(result.id), label: result.display_number || `EPIC-${result.id}`, detail: result.title }))}
                selected={epicDeps}
                setQuery={setEpicQuery}
                setSelected={setEpicDeps}
              />
            </div>
            {proposal.epic_bundle ? (
              <label className="block rounded border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-950 dark:border-amber-900/70 dark:bg-amber-950/40 dark:text-amber-100">
                <span className="flex items-start gap-2 font-medium">
                  <input
                    checked={nonlinearDependencyOverride}
                    className="mt-0.5 h-4 w-4 rounded border-amber-300 text-amber-700 focus:ring-amber-500 dark:border-amber-700"
                    onChange={(event) => setNonlinearDependencyOverride(event.target.checked)}
                    type="checkbox"
                  />
                  <span>{t("nonlinear_override_label")}</span>
                </span>
                <span className="mt-1 block pl-6 text-xs text-amber-900 dark:text-amber-100">
                  {t("nonlinear_override_help")}
                </span>
              </label>
            ) : null}
          </div>
          <div className="flex justify-end gap-2 border-t border-gray-200 px-5 py-4 dark:border-gray-800">
            <button className={secondaryButton()} onClick={onClose} type="button">{t("cancel")}</button>
            <button className={primaryButton()} disabled={save.isPending || title.trim().length === 0} type="submit">{t("save")}</button>
          </div>
        </form>
      </div>
    </div>
  )
}

function DependencyPicker({ label, placeholder, query, results, selected, setQuery, setSelected }: { label: string; placeholder: string; query: string; results: DependencyPill[]; selected: DependencyPill[]; setQuery: (query: string) => void; setSelected: (selected: DependencyPill[]) => void }) {
  const selectedKeys = new Set(selected.map((item) => item.key))
  const availableResults = results.filter((item) => !selectedKeys.has(item.key))
  return (
    <div>
      <label className="block text-sm font-medium text-gray-700 dark:text-gray-200">
        {label}
        <input
          className="mt-1 w-full rounded border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100"
          onChange={(event) => setQuery(event.target.value)}
          placeholder={placeholder}
          type="text"
          value={query}
        />
      </label>
      {availableResults.length > 0 ? (
        <div className="mt-1 max-h-36 overflow-y-auto rounded border border-gray-200 bg-white shadow-sm dark:border-gray-800 dark:bg-gray-900">
          {availableResults.map((result) => (
            <button
              className="block w-full px-3 py-2 text-left text-sm hover:bg-blue-50 dark:hover:bg-blue-950"
              key={result.key}
              onClick={() => {
                setSelected([...selected, result])
                setQuery("")
              }}
              type="button"
            >
              <span className="font-medium text-gray-900 dark:text-gray-100">{result.label}</span>
              {result.detail ? <span className="ml-2 text-gray-500 dark:text-gray-400">{result.detail}</span> : null}
            </button>
          ))}
        </div>
      ) : null}
      <div className="mt-2 flex flex-wrap gap-2">
        {selected.map((item) => (
          <span className="inline-flex max-w-full items-center gap-1 rounded border border-gray-200 bg-gray-50 px-2 py-1 text-xs text-gray-700 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-200" key={item.key}>
            <span className="min-w-0 truncate font-medium">{item.label}</span>
            {item.detail ? <span className="min-w-0 truncate text-gray-500 dark:text-gray-400">{item.detail}</span> : null}
            <button className="ml-1 rounded text-gray-400 hover:text-red-600 dark:hover:text-red-300" onClick={() => setSelected(selected.filter((selectedItem) => selectedItem.key !== item.key))} type="button" aria-label={`Remove ${item.label}`}>
              <CloseIcon className="h-3 w-3" />
            </button>
          </span>
        ))}
      </div>
    </div>
  )
}

function useDebouncedDependencySearch<T>(query: string, searcher: (query: string, signal: AbortSignal) => Promise<T[]>, setResults: (results: T[]) => void) {
  useEffect(() => {
    const trimmed = query.trim()
    if (trimmed.length === 0) {
      setResults([])
      return
    }

    const controller = new AbortController()
    const timer = window.setTimeout(() => {
      searcher(trimmed, controller.signal)
        .then(setResults)
        .catch((error) => {
          if (error.name !== "AbortError") setResults([])
        })
    }, 200)

    return () => {
      window.clearTimeout(timer)
      controller.abort()
    }
  }, [query, searcher, setResults])
}

type ProposalActionInput = { action: "confirm" | "reject"; path: string; start?: boolean }

export function ProposalCard({ proposal, prefix, queryKey, onNotice }: { proposal: ChatProposal; prefix: string; queryKey: ChatQueryKey; onNotice: (message: string | null) => void }) {
  const { t } = useT("chat")
  const queryClient = useQueryClient()
  const search = queryKey[2]
  const [editingProposal, setEditingProposal] = useState<EditableProposal | null>(null)
  const childJobCount = proposal.children?.length || 0
  const bootstrap = useQuery({ queryKey: ["bootstrap"], queryFn: fetchBootstrap })
  const currentUser = bootstrap.data?.current_user
  const showConfirmAndStart = proposal.epic_bundle && (currentUser?.role === "developer" || currentUser?.admin === true)
  const proposalAction = useMutation({
    mutationFn: (input: ProposalActionInput) => {
      const path = appendSearch(input.path, search)
      return input.action === "confirm" ? confirmChatProposal(path, { start: input.start }) : rejectChatProposal(path)
    },
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || null)
    }
  })

  return (
    <>
      <ConfirmationCard
        muted={proposal.resolved}
        proposalCard
        header={
          <>
            <div className="flex items-start justify-between gap-3">
              <div className="flex flex-wrap items-center gap-2">
                <span className="rounded bg-indigo-50 px-2 py-0.5 text-xs font-medium text-indigo-700 dark:bg-indigo-950 dark:text-indigo-200">{proposal.epic_bundle ? "Epic" : proposal.kind_label}</span>
                <span className={`rounded px-2 py-0.5 text-xs font-medium ${proposal.proposed ? "bg-blue-50 text-blue-700 dark:bg-blue-950 dark:text-blue-200" : "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-300"}`}>{proposal.state_label}</span>
                {proposal.epic_bundle ? <span className="rounded bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-600 dark:bg-gray-800 dark:text-gray-300">{proposal.active_children_count || 0} child Jobs</span> : null}
                {proposal.epic_bundle && proposal.nonlinear_dependency_override ? <span className="rounded bg-amber-50 px-2 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-950/50 dark:text-amber-200">{t("nonlinear_override_badge")}</span> : null}
              </div>
              {proposal.proposed ? <ProposalEditButton label={`Edit ${proposal.slug}`} onClick={() => setEditingProposal(proposal)} /> : null}
            </div>
          <ProposalDependencyStrip dependencies={proposal.dependencies} hasDependencies={proposal.has_dependencies} prefix={prefix} />
          <h3 className="mt-2 text-base font-semibold text-gray-900 dark:text-gray-100">{proposal.title}</h3>
          <p className="mt-1 font-mono text-xs text-gray-500 dark:text-gray-400">{proposal.slug}</p>
        </>
      }
      body={
        <>
          <Markdown className="chat-prose text-sm text-gray-800 dark:text-gray-100" text={proposal.body} />
          {proposal.epic_bundle && proposal.nonlinear_dependency_override ? (
            <p className="mt-3 rounded border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-900 dark:border-amber-900/70 dark:bg-amber-950/40 dark:text-amber-100">
              {t("nonlinear_override_notice")}
            </p>
          ) : null}
          {proposal.epic_bundle ? <ProposalChildren children={proposal.children || []} parentProposed={proposal.proposed} mutation={proposalAction} prefix={prefix} onEdit={(child) => setEditingProposal(editableChildProposal(child))} /> : <ProposalMeta proposal={proposal} />}
        </>
      }
      footer={
        <>
          <ProposalResultFooter proposal={proposal} prefix={prefix} onNotice={onNotice} />
          {proposal.proposed ? (
            <div className="mt-4 flex flex-wrap gap-2">
              <button
                className={showConfirmAndStart ? secondaryButton() : primaryButton()}
                disabled={proposalAction.isPending}
                onClick={() => proposalAction.mutate({ action: "confirm", path: proposal.app_confirm_path })}
                type="button"
              >
                {proposalConfirmLabel(proposal, childJobCount)}
              </button>
              {showConfirmAndStart ? (
                <button
                  className={primaryButton()}
                  disabled={proposalAction.isPending}
                  onClick={() => proposalAction.mutate({ action: "confirm", path: proposal.app_confirm_path, start: true })}
                  type="button"
                >
                  {t("create_epic_and_start")}
                </button>
              ) : null}
              <button
                className={secondaryButton()}
                disabled={proposalAction.isPending}
                onClick={() => proposalAction.mutate({ action: "reject", path: proposal.app_reject_path })}
                type="button"
              >
                Reject
              </button>
              {proposalAction.isError ? <div className="basis-full text-xs text-red-700 dark:text-red-300">{errorMessage(proposalAction.error, "Proposal command failed.")}</div> : null}
            </div>
          ) : null}
        </>
      }
      />
      {editingProposal ? <ProposalEditModal chatId={queryKey[1]} proposal={editingProposal} search={search} queryKey={queryKey} onClose={() => setEditingProposal(null)} onNotice={onNotice} /> : null}
    </>
  )
}

function ProposalEditButton({ label, onClick }: { label: string; onClick: (event: ReactMouseEvent<HTMLButtonElement>) => void }) {
  return (
    <button className="shrink-0 rounded border border-gray-200 p-1.5 text-gray-500 hover:border-blue-200 hover:bg-blue-50 hover:text-blue-700 dark:border-gray-700 dark:text-gray-400 dark:hover:border-blue-800 dark:hover:bg-blue-950 dark:hover:text-blue-200" onClick={onClick} type="button" aria-label={label}>
      <PencilIcon className="h-4 w-4" />
    </button>
  )
}

export function PendingActionCard({ pendingAction, queryKey, onNotice, onSelectMessage }: { pendingAction: ChatPendingActionInline | ChatPendingAction; queryKey: ChatQueryKey; onNotice: (message: string | null) => void; onSelectMessage?: (messageId: number) => void }) {
  const queryClient = useQueryClient()
  const search = queryKey[2]
  const action = useMutation({
    mutationFn: (input: { action: "confirm" | "reject"; path: string }) => {
      const path = appendSearch(input.path, search)
      return input.action === "confirm" ? confirmPendingAction(path) : rejectPendingAction(path)
    },
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || null)
    }
  })
  const terminalLabel = pendingActionTerminalLabel(pendingAction.state)
  const actionKey = pendingActionKey(pendingAction)
  const rejectLabel = actionKey === "schedule_recurring" ? "Cancel" : "Decline"
  const isQueued = pendingAction.state === "queued"
  const isPending = pendingAction.state === "pending"
  const rejectPath = pendingAction.app_reject_path
  const chatMessageId = "chat_message_id" in pendingAction ? pendingAction.chat_message_id : null
  const resourceTitle = pendingActionResourceTitle(pendingAction)
  const resourceUrl = pendingActionResourceUrl(pendingAction)

  return (
    <ConfirmationCard
      muted={Boolean(terminalLabel)}
      header={
        <>
          <div className="flex flex-wrap items-center gap-2">
            <span className="rounded bg-indigo-50 px-2 py-0.5 text-xs font-medium text-indigo-700 dark:bg-indigo-950 dark:text-indigo-200">{pendingActionBadgeLabel(pendingAction)}</span>
            <span className={`rounded px-2 py-0.5 text-xs font-medium ${isPending ? "bg-blue-50 text-blue-700 dark:bg-blue-950 dark:text-blue-200" : "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-300"}`}>{isQueued ? "Waiting..." : terminalLabel || "Needs confirmation"}</span>
          </div>
          {chatMessageId && onSelectMessage ? (
            <h3 className="mt-2 text-base font-semibold">
              <a
                className="break-words text-blue-700 hover:underline dark:text-blue-300"
                href={`#message-${chatMessageId}`}
                onClick={(event) => {
                  event.preventDefault()
                  onSelectMessage(chatMessageId)
                }}
              >
                {pendingAction.label}
              </a>
            </h3>
          ) : (
            <h3 className="mt-2 text-base font-semibold text-gray-900 dark:text-gray-100">{terminalLabel ? pendingAction.label : linkifySlugs(pendingAction.label)}</h3>
          )}
        </>
      }
      body={
        resourceTitle || pendingAction.detail ? (
          <>
            {resourceTitle && resourceUrl ? (
              <a className="inline-block break-words text-sm font-medium text-blue-700 hover:underline dark:text-blue-300" href={resourceUrl}>{resourceTitle}</a>
            ) : resourceTitle ? (
              <p className="break-words text-sm font-medium text-gray-700 dark:text-gray-300">{resourceTitle}</p>
            ) : null}
            {pendingAction.detail ? <PendingActionDetail detail={pendingAction.detail} /> : null}
          </>
        ) : null
      }
      footer={
        terminalLabel ? (
          <div className="flex flex-wrap items-center gap-2 border-t border-gray-100 pt-3 text-xs text-gray-600 dark:border-gray-800 dark:text-gray-300">
            <span className={`rounded px-2 py-0.5 font-medium ${pendingAction.state === "confirmed" ? "bg-green-50 text-green-700 dark:bg-green-950 dark:text-green-200" : "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-200"}`}>{terminalLabel}</span>
          </div>
        ) : isPending ? (
          <div className="flex flex-wrap gap-2">
            <button
              className={primaryButton()}
              disabled={action.isPending}
              onClick={() => action.mutate({ action: "confirm", path: pendingAction.app_confirm_path })}
              type="button"
            >
              Confirm
            </button>
            <button
              className={secondaryButton()}
              disabled={action.isPending}
              onClick={() => action.mutate({ action: "reject", path: rejectPath })}
              type="button"
            >
              {rejectLabel}
            </button>
            {action.isError ? <div className="basis-full text-xs text-red-700 dark:text-red-300">{errorMessage(action.error, "Pending action failed.")}</div> : null}
          </div>
        ) : null
      }
    />
  )
}

function PendingActionDetail({ detail }: { detail: string }) {
  return (
    <div className="mt-2 max-h-40 overflow-y-auto rounded border border-gray-200 bg-gray-50 px-3 py-2 dark:border-gray-800 dark:bg-gray-950">
      <Markdown className="chat-prose text-xs text-gray-700 dark:text-gray-300" text={detail} />
    </div>
  )
}

function ProposalDependencyStrip({ dependencies, hasDependencies, prefix }: { dependencies: ChatProposalDependency[]; hasDependencies: boolean; prefix: string }) {
  const { t } = useT("chat")
  if (!hasDependencies) {
    return <div className="mt-2 text-xs font-medium text-gray-500 dark:text-gray-400">{t("no_dependencies")}</div>
  }

  return (
    <div className="mt-2 flex flex-wrap items-center gap-2 text-xs text-gray-600 dark:text-gray-300">
      <span className="font-medium text-gray-700 dark:text-gray-200">Depends on:</span>
      {dependencies.map((dependency) => (
        <ProposalDependencyLink dependency={dependency} key={dependency.slug} prefix={prefix} />
      ))}
    </div>
  )
}

function ProposalDependencyLink({ dependency, prefix }: { dependency: ChatProposalDependency; prefix: string }) {
  const title = dependency.display_label || dependency.materialized_label || dependency.title
  const label = dependency.display_label ? title : `${title} ${dependency.confirmed ? "✓" : "⏳"}`
  const className = "inline-flex max-w-full items-center gap-1 rounded border border-gray-200 bg-gray-50 px-2 py-0.5 font-medium text-gray-700 hover:border-blue-200 hover:bg-blue-50 hover:text-blue-700 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-200 dark:hover:border-blue-800 dark:hover:bg-blue-950 dark:hover:text-blue-200"

  if (dependency.anchor_message_id) {
    return <a className={className} href={`#message-${dependency.anchor_message_id}`}>{label}</a>
  }

  if (dependency.materialized_path) {
    return <Link className={className} to={withRoutePrefix(dependency.materialized_path, prefix)}>{label}</Link>
  }

  return <span className={className}>{label}</span>
}

function ProposalResultFooter({ proposal, prefix, onNotice }: { proposal: ChatProposal; prefix: string; onNotice: (message: string | null) => void }) {
  const { t } = useT("chat")
  if (proposal.state === "confirmed") {
    return (
      <div className="mt-4 flex flex-wrap items-center gap-2 border-t border-gray-100 pt-3 text-xs text-gray-600 dark:border-gray-800 dark:text-gray-300">
        <span className="rounded bg-green-50 px-2 py-0.5 font-medium text-green-700 dark:bg-green-950 dark:text-green-200">{t("confirmed")}</span>
        <ProposalMaterializedResult proposal={proposal} prefix={prefix} />
        <StartEpicButton proposal={proposal} onNotice={onNotice} />
      </div>
    )
  }

  if (proposal.state === "rejected" || proposal.state === "withdrawn") {
    const label = proposal.state === "withdrawn" ? "Withdrawn" : "Rejected"
    return (
      <div className="mt-4 flex flex-wrap items-center gap-2 border-t border-gray-100 pt-3 text-xs text-gray-600 dark:border-gray-800 dark:text-gray-300">
        <span className="rounded bg-gray-100 px-2 py-0.5 font-medium text-gray-700 dark:bg-gray-800 dark:text-gray-200">{label}</span>
      </div>
    )
  }

  return null
}

function ProposalMaterializedResult({ proposal, prefix }: { proposal: ChatProposal; prefix: string }) {
  const materialized = proposal.materialized
  if (materialized?.kind === "job") {
    const label = proposal.materialized_label || `JOB-${materialized.job_id}`
    return (
      <span>
        → <ProposalResultLink path={proposal.materialized_path} prefix={prefix}>{label}</ProposalResultLink>{materialized.job_title ? ` "${materialized.job_title}"` : ""}
      </span>
    )
  }

  if (materialized?.kind === "epic") {
    const children = materialized.child_jobs.filter((job) => job.job_id)
    return (
      <>
        <span>
          → Epic <ProposalResultLink path={proposal.materialized_path} prefix={prefix}>#{materialized.epic_id}</ProposalResultLink>{materialized.epic_title ? ` "${materialized.epic_title}"` : ""}
        </span>
        {children.length > 0 ? (
          <span className="basis-full sm:basis-auto">
            Jobs: {children.map((job, index) => (
              <span key={`${job.job_id}-${index}`}>
                {index > 0 ? ", " : ""}
                JOB-{job.job_id}{job.title ? ` "${job.title}"` : ""}
              </span>
            ))}
          </span>
        ) : null}
      </>
    )
  }

  if (proposal.materialized_label && proposal.materialized_path) {
    return (
      <span>
        → <ProposalResultLink path={proposal.materialized_path} prefix={prefix}>{proposal.materialized_label}</ProposalResultLink>
      </span>
    )
  }

  return null
}

function ProposalResultLink({ path, prefix, children }: { path: string | null; prefix: string; children: ReactNode }) {
  if (!path) return <>{children}</>

  return <Link className="font-medium text-blue-700 hover:underline dark:text-blue-300" to={withRoutePrefix(path, prefix)}>{children}</Link>
}

function ProposalMeta({ proposal }: { proposal: ChatProposal }) {
  const { t } = useT("chat")
  return (
    <dl className="mt-3 grid gap-2 text-xs text-gray-600 sm:grid-cols-2 dark:text-gray-300">
      <div><dt className="font-medium text-gray-500 dark:text-gray-400">{t("attached_scope")}</dt><dd>{proposal.scoped_repository_slug || t("no_repository_attached")}</dd></div>
      <div>
        <dt className="font-medium text-gray-500 dark:text-gray-400">{t("dependencies")}</dt>
        <dd>{(proposal.dependency_slugs || []).length > 0 ? <PillList values={proposal.dependency_slugs || []} /> : t("none")}</dd>
      </div>
      {proposal.target_epic_label ? <div><dt className="font-medium text-gray-500 dark:text-gray-400">{t("target_epic")}</dt><dd>{proposal.target_epic_label}</dd></div> : null}
    </dl>
  )
}

function ProposalChildren({ children, parentProposed, mutation, prefix, onEdit }: { children: ChatProposalChild[]; parentProposed: boolean; mutation: UseMutationResult<ChatPayload, Error, ProposalActionInput>; prefix: string; onEdit: (child: ChatProposalChild) => void }) {
  if (children.length === 0) return null
  return (
    <div className="mt-4 divide-y divide-gray-100 rounded border border-gray-200 dark:divide-gray-800 dark:border-gray-700">
      {children.map((child) => (
        <details className="group" key={child.id}>
          <summary className="flex cursor-pointer items-center gap-3 px-3 py-2 text-sm hover:bg-gray-50 dark:hover:bg-gray-800">
            <span className="text-gray-400 group-open:rotate-90 dark:text-gray-500">▸</span>
            <span className="min-w-0 flex-1 truncate font-medium text-gray-900 dark:text-gray-100">{child.title}</span>
            {child.dependencies.length > 0 ? <ChildDependencySummary child={child} prefix={prefix} /> : null}
            <span className={`shrink-0 rounded px-2 py-0.5 text-xs font-medium ${child.proposed ? "bg-blue-50 text-blue-700 dark:bg-blue-950 dark:text-blue-200" : "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-300"}`}>{child.state_label}</span>
            {child.proposed && parentProposed ? <ProposalEditButton label={`Edit ${child.slug}`} onClick={(event) => { event.stopPropagation(); onEdit(child) }} /> : null}
          </summary>
          <div className="border-t border-gray-100 px-8 py-3 text-sm text-gray-700 dark:border-gray-800 dark:text-gray-300">
            <div className="flex flex-wrap items-center gap-2 text-xs text-gray-500 dark:text-gray-400"><span className="font-mono">{child.slug}</span><span>{child.repository_slug || "No repository attached"}</span></div>
            <Markdown className="chat-prose mt-2 text-sm text-gray-800 dark:text-gray-100" text={child.body} />
            {child.proposed && parentProposed ? (
              <div className="mt-3">
                <button
                  className="rounded border border-red-200 px-3 py-1.5 text-sm font-medium text-red-700 hover:bg-red-50 disabled:text-gray-300 dark:border-red-800 dark:text-red-300 dark:hover:bg-red-950 dark:disabled:text-gray-600"
                  disabled={mutation.isPending}
                  onClick={() => mutation.mutate({ action: "reject", path: child.app_reject_path })}
                  type="button"
                >
                  Reject child Job
                </button>
              </div>
            ) : null}
          </div>
        </details>
      ))}
    </div>
  )
}

function ChildDependencySummary({ child, prefix }: { child: ChatProposalChild; prefix: string }) {
  const details = child.dependency_details || []
  const collapsedPillClass = "shrink-0 rounded bg-gray-100 px-2 py-0.5 text-xs text-gray-600 dark:bg-gray-800 dark:text-gray-300"

  if (details.length === 0) {
    if (child.dependencies.length >= 2) {
      return <span className={collapsedPillClass} title={child.dependencies.join(", ")}>{child.dependencies.length} dependencies</span>
    }
    return <span className="shrink-0 rounded bg-gray-100 px-2 py-0.5 font-mono text-xs text-gray-600 dark:bg-gray-800 dark:text-gray-300">depends on {child.dependencies.join(", ")}</span>
  }

  if (details.length >= 2) {
    return <span className={collapsedPillClass} title={details.map((d) => d.slug).join(", ")}>{details.length} dependencies</span>
  }

  return (
    <span className="flex shrink-0 flex-wrap items-center justify-end gap-1 text-xs">
      <span className="text-gray-500 dark:text-gray-400">depends on</span>
      {details.map((dependency) => (
        <ChildDependencyPill dependency={dependency} key={dependency.slug} prefix={prefix} />
      ))}
    </span>
  )
}

function ChildDependencyPill({ dependency, prefix }: { dependency: ChatProposalChildDependency; prefix: string }) {
  const label = dependency.materialized_label || dependency.slug
  const scopeLabel = dependency.scope === "cross_card" ? "cross-card" : "sibling"
  const className = dependency.scope === "cross_card"
    ? "rounded border border-blue-200 bg-blue-50 px-2 py-0.5 font-mono text-xs text-blue-700 dark:border-blue-800 dark:bg-blue-950 dark:text-blue-200"
    : "rounded bg-gray-100 px-2 py-0.5 font-mono text-xs text-gray-600 dark:bg-gray-800 dark:text-gray-300"
  const content = <>{label}<span className="ml-1 font-sans text-[10px] uppercase">{scopeLabel}</span></>

  if (dependency.materialized_path) {
    return <Link className={className} to={withRoutePrefix(dependency.materialized_path, prefix)}>{content}</Link>
  }

  return <span className={className}>{content}</span>
}
