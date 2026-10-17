import type { ChatComposeAttachment } from "./composeTypes"

export type InFlightComposerDraft = {
  composerText: string
  attachments: ChatComposeAttachment[]
}

// Submission recovery must survive a Compose remount without remaining visible
// to the next Compose instance as an editable draft. The request callback owns
// removal; a failed callback may copy this snapshot back to the editable stores.
const draftsByChatId = new Map<string, InFlightComposerDraft>()

export function setInFlightComposerDraft(chatId: string, draft: InFlightComposerDraft): void {
  draftsByChatId.set(chatId, draft)
}

export function clearInFlightComposerDraft(chatId: string, draft: InFlightComposerDraft): boolean {
  if (draftsByChatId.get(chatId) !== draft) return false
  draftsByChatId.delete(chatId)
  return true
}

export function __resetInFlightComposerDraftsForTests(): void {
  draftsByChatId.clear()
}
