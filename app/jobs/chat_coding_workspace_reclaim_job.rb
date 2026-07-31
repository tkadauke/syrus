# Reclaims a Coding-Mode chat's on-disk checkout (the ~1-2 GB writable clone +
# installed deps) once it is fully reproducible from the remote — chiefly right
# after a successful coding handoff, when the branch is pushed and the PR is
# open.
#
# Runs on the `chat` queue so it executes on the single worker that consumes
# chat work and therefore owns the chat workspace on local disk. The handoff
# Workflow that triggers it runs on a compute pod, which cannot see that disk —
# hence the hop back to `chat`.
#
# reclaim_coding_checkout! backs up any un-pushed / uncommitted work to the
# remote before deleting. Standalone chat work is backed up through the
# per-chat WIP tag instead of a persistent `syrus-chat-<id>` branch; existing
# Job branch checkouts still restore from their Job branch. A live turn holding
# the workspace open is unaffected: the reclaim just frees disk that ensure_
# coding_checkout! will re-clone on demand.
class ChatCodingWorkspaceReclaimJob < ApplicationJob
  queue_as :chat

  def perform(chat_session_id)
    chat_session = ChatSession.find_by(id: chat_session_id)
    return unless chat_session
    return if chat_session.coding_checkout_branch.blank?

    ChatWorkspace.reclaim_coding_checkout!(chat_session)
  rescue StandardError => e
    Rails.logger.warn("[ChatCodingWorkspaceReclaim] chat #{chat_session_id}: #{e.class}: #{e.message}")
  end
end
