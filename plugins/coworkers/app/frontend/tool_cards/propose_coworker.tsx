import { useMutation } from "@tanstack/react-query"
import { useEffect, useState } from "react"
import { patchJson, postJson } from "@app/api/client"
import { Avatar } from "@app/components/Avatar"
import { Textarea } from "@app/components/Textarea"
import i18n from "@app/i18n"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, Row, StatePill } from "@app/routes/chat/toolCardUi"

function values(context: ToolCardContext) {
  if (!isPlainObject(context.parsedResult) || !isPlainObject(context.parsedResult.coworker)) return null
  const id = displayValue(context.parsedResult.pending_action_id)
  if (!id) return null
  const live = context.livePendingAction && displayValue(context.livePendingAction.id) === id ? context.livePendingAction : null
  return { state: live?.state || displayValue(context.parsedResult.state) || "pending", coworker: context.parsedResult.coworker, live }
}
function optional(value: unknown) {
  return displayValue(value) || i18n.t("coworkers:tool_card.account_default")
}

function CoworkerProposalCard({ context }: { context: ToolCardContext }) {
  const card = values(context)!
  const reviewedAbout = isPlainObject(card.live?.review) ? displayValue(card.live.review.about) : null
  const about = reviewedAbout ?? displayValue(card.coworker.about) ?? ""
  const [draft, setDraft] = useState(about)
  const [savedAbout, setSavedAbout] = useState(about)
  const [actionState, setActionState] = useState(card.state)
  useEffect(() => {
    setDraft(about)
    setSavedAbout(about)
  }, [about])
  useEffect(() => setActionState(card.state), [card.state])
  const updatePath = card.live?.app_update_path
  const save = useMutation({
    mutationFn: (reviewedAbout: string) => patchJson(updatePath!, { about: reviewedAbout }),
    onSuccess: (_response, reviewedAbout) => setSavedAbout(reviewedAbout)
  })
  const decide = useMutation({
    mutationFn: async ({ path, state }: { path: string; state: "confirming" | "rejected" }) => {
      if (state === "confirming" && updatePath && draft !== savedAbout) await patchJson(updatePath, { about: draft })
      return postJson(path)
    },
    onSuccess: (_response, decision) => setActionState(decision.state)
  })
  const grants = isPlainObject(card.coworker.grant_policies) ? Object.entries(card.coworker.grant_policies) : []
  const outcome = card.live?.outcome
  const coworkerId = isPlainObject(outcome) ? displayValue(outcome.coworker_id) : ""
  const chatId = isPlainObject(outcome) ? displayValue(outcome.chat_id) : ""
  const failedReason = card.live?.execution_error || card.live?.reason

  return (
    <CardShell>
      <div className="flex min-w-0 max-w-full flex-wrap items-center gap-3">
        <Avatar
          avatarKey={displayValue(card.coworker.avatar_key) || null}
          avatarUrl={null}
          accentHex={displayValue(card.coworker.accent_hex) || null}
          name={displayValue(card.coworker.name) || ""}
        />
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <span className="min-w-0 break-words text-sm font-semibold text-text-primary [overflow-wrap:anywhere]">{displayValue(card.coworker.name)}</span>
            <StatePill state={actionState} />
          </div>
          <div className="truncate text-xs text-text-secondary">@{displayValue(card.coworker.handle)}</div>
        </div>
      </div>
      <dl className="grid min-w-0 max-w-full gap-2 sm:grid-cols-2">
        <Row label={i18n.t("coworkers:fields.model")} value={[optional(card.coworker.chat_provider), optional(card.coworker.chat_model)].join(" · ")} />
        <Row label={i18n.t("coworkers:fields.remote")} value={displayValue(card.coworker.workspace_repo)} />
        <Row label={i18n.t("coworkers:fields.branch")} value={displayValue(card.coworker.branch) || `coworkers/${displayValue(card.coworker.handle)}`} />
        <Row label={i18n.t("coworkers:fields.effort")} value={optional(card.coworker.chat_effort)} />
      </dl>
      <div>
        <div className="mb-1 text-xs font-medium text-text-secondary">{i18n.t("coworkers:fields.grants")}</div>
        <ul className="grid min-w-0 max-w-full gap-1 sm:grid-cols-2">
          {grants.map(([capability, policy]) => (
            <li className="flex min-w-0 max-w-full items-center justify-between gap-2 rounded bg-surface-subtle px-2 py-1 text-xs" key={capability}>
              <code className="min-w-0 break-all whitespace-normal">{capability}</code>
              <span className="shrink-0 rounded bg-neutral-surface px-1.5 py-0.5 font-medium text-neutral-text">{displayValue(policy)}</span>
            </li>
          ))}
        </ul>
      </div>
      <label className="block min-w-0 max-w-full text-xs font-medium text-text-secondary">
        {i18n.t("coworkers:fields.about")}
        <Textarea
          aria-label={i18n.t("coworkers:fields.about")}
          className="mt-1 min-h-24 w-full max-w-full"
          disabled={actionState !== "pending" || !updatePath}
          onChange={(event) => setDraft(event.target.value)}
          value={draft}
        />
      </label>
      {actionState === "pending" && updatePath ? (
        <div className="flex flex-wrap items-center gap-2">
          <button
            className="rounded bg-brand px-3 py-1.5 text-xs font-medium text-white disabled:opacity-50"
            disabled={save.isPending || draft === savedAbout}
            onClick={() => save.mutate(draft)}
            type="button"
          >
            {i18n.t("coworkers:tool_card.save_about")}
          </button>
          {save.isSuccess ? <span className="text-xs text-success">{i18n.t("coworkers:tool_card.about_saved")}</span> : null}
          {save.isError ? <span className="text-xs text-danger">{save.error.message}</span> : null}
        </div>
      ) : null}
      {actionState === "pending" && card.live ? (
        <div className="flex flex-wrap gap-2 border-t border-border pt-2">
          <button
            className="rounded bg-brand px-3 py-1.5 text-xs font-medium text-white disabled:opacity-50"
            disabled={decide.isPending}
            onClick={() => decide.mutate({ path: card.live!.app_confirm_path, state: "confirming" })}
            type="button"
          >
            {i18n.t("coworkers:tool_card.confirm")}
          </button>
          <button
            className="rounded border border-border px-3 py-1.5 text-xs font-medium text-text-primary disabled:opacity-50"
            disabled={decide.isPending}
            onClick={() => decide.mutate({ path: card.live!.app_reject_path, state: "rejected" })}
            type="button"
          >
            {i18n.t("coworkers:tool_card.reject")}
          </button>
        </div>
      ) : null}
      {decide.isError ? <p className="break-words text-xs text-danger">{decide.error.message}</p> : null}
      {failedReason ? <p className="break-words text-xs text-danger [overflow-wrap:anywhere]">{failedReason}</p> : null}
      {actionState === "confirmed" && coworkerId ? (
        <div className="flex flex-wrap gap-3 text-sm">
          <a className="font-medium text-brand hover:underline" href={`/coworkers/${coworkerId}`}>
            {i18n.t("coworkers:tool_card.open_coworker")}
          </a>
          {chatId ? (
            <a className="font-medium text-brand hover:underline" href={`/chats/${chatId}`}>
              {i18n.t("coworkers:tool_card.open_chat")}
            </a>
          ) : null}
        </div>
      ) : null}
    </CardShell>
  )
}

const proposeCoworkerToolCard: ToolCardRenderer = {
  toolName: "propose_coworker",
  argumentSummary: () => "",
  collapsedSummary(context) {
    const card = values(context)
    return card ? i18n.t("coworkers:tool_card.summary", { handle: displayValue(card.coworker.handle) }) : null
  },
  renderExpanded(context) {
    return values(context) ? <CoworkerProposalCard context={context} /> : null
  }
}
const exampleResult = {
  pending_action_id: 501,
  state: "pending",
  coworker: {
    name: "Maya",
    handle: "maya",
    workspace_repo: "https://github.com/acme/coworkers.git",
    branch: "coworkers/maya",
    about: "Research lead",
    accent_hex: "#E5484D",
    avatar_key: "comet",
    chat_provider: "codex",
    chat_model: "gpt-5.6-sol",
    chat_effort: "high",
    grants: ["workspace.files", "syrus.propose_job"],
    grant_policies: { "workspace.files": "auto", "syrus.propose_job": "confirm" }
  }
}

const liveExample = (state: "pending" | "confirmed" | "rejected" | "failed", extra: Record<string, unknown> = {}) => ({
  id: 501,
  action: "create_coworker",
  state,
  label: "Create coworker @maya",
  detail: "Maya · https://github.com/acme/coworkers.git",
  app_confirm_path: "/api/v1/app/chats/44/pending_actions/501/confirm",
  app_reject_path: "/api/v1/app/chats/44/pending_actions/501/reject",
  ...extra
})

export const examples: ToolCardExample[] = [
  {
    id: "pending",
    label: i18n.t("coworkers:tool_card.example_pending"),
    input: { name: "Maya" },
    parsedResult: exampleResult,
    livePendingAction: liveExample("pending", { app_update_path: "/api/v1/app/chats/44/pending_actions/501", review: { about: "Research lead" } })
  },
  {
    id: "confirmed",
    label: i18n.t("coworkers:tool_card.example_confirmed"),
    input: { name: "Maya" },
    parsedResult: exampleResult,
    livePendingAction: liveExample("confirmed", { review: { about: "Research lead" }, outcome: { coworker_id: 12, chat_id: 44 } })
  },
  {
    id: "rejected",
    label: i18n.t("coworkers:tool_card.example_rejected"),
    input: { name: "Maya" },
    parsedResult: exampleResult,
    livePendingAction: liveExample("rejected", { reason: "The owner declined this coworker." })
  },
  {
    id: "failed",
    label: i18n.t("coworkers:tool_card.example_failed"),
    input: { name: "Maya" },
    parsedResult: exampleResult,
    livePendingAction: liveExample("failed", { execution_error: "Push access to the workspace remote was denied." })
  }
]
export default proposeCoworkerToolCard
