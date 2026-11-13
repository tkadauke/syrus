import type { ChatComposeAttachment } from "./composeTypes"

export type InFlightComposerDraft = {
  composerText: string
  attachments: ChatComposeAttachment[]
  clientIdempotencyKey?: string
}

// Submission recovery must survive a Compose remount without remaining visible
// to the next Compose instance as an editable draft. The request callback owns
// removal; a failed callback may copy this snapshot back to the editable stores.
const draftsByChatId = new Map<string, InFlightComposerDraft>()
let acknowledgedDrafts = new WeakSet<InFlightComposerDraft>()
const acknowledgmentListenersByChatId = new Map<string, Set<(draft: InFlightComposerDraft) => void>>()

export function setInFlightComposerDraft(chatId: string, draft: InFlightComposerDraft): void {
  draftsByChatId.set(chatId, draft)
}

export function clearInFlightComposerDraft(chatId: string, draft: InFlightComposerDraft): boolean {
  if (draftsByChatId.get(chatId) !== draft) return false
  draftsByChatId.delete(chatId)
  return true
}

export function getInFlightComposerDraft(chatId: string): InFlightComposerDraft | undefined {
  return draftsByChatId.get(chatId)
}

export function acknowledgeInFlightComposerDraft(chatId: string, clientIdempotencyKey: string): boolean {
  const draft = draftsByChatId.get(chatId)
  if (!draft || draft.clientIdempotencyKey !== clientIdempotencyKey) return false

  acknowledgedDrafts.add(draft)
  acknowledgmentListenersByChatId.get(chatId)?.forEach((listener) => listener(draft))
  return true
}

export function inFlightComposerDraftWasAcknowledged(draft: InFlightComposerDraft): boolean {
  return acknowledgedDrafts.has(draft)
}

export function subscribeToInFlightComposerDraftAcknowledgments(
  chatId: string,
  listener: (draft: InFlightComposerDraft) => void
): () => void {
  const listeners = acknowledgmentListenersByChatId.get(chatId) || new Set()
  listeners.add(listener)
  acknowledgmentListenersByChatId.set(chatId, listeners)

  return () => {
    listeners.delete(listener)
    if (listeners.size === 0) acknowledgmentListenersByChatId.delete(chatId)
  }
}

export function __resetInFlightComposerDraftsForTests(): void {
  draftsByChatId.clear()
  acknowledgedDrafts = new WeakSet()
  acknowledgmentListenersByChatId.clear()
}
