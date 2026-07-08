# Removes everything a deleted chat leaves behind outside the primary
# DB transaction: the chat workspace directory, the per-chat agent
# homes under agent_homes/chats/<id>/, and the FTS search-index rows.
#
# Enqueued from ChatSession's after_destroy_commit, so a rolled-back
# destroy never fires it, and it runs on the `chat` queue — i.e. on the
# worker pod, where the workspace PVC is actually mounted. The web pod
# that served the DELETE request has no workspace filesystem, so an
# inline rm_rf there was a silent no-op in the documented K8s topology.
#
# The FTS purge also runs here, after the ChatSession row is gone: a
# concurrently-running IndexChatMessageJob re-checks the chat's
# existence before inserting (see ChatMessageSearchIndex.insert), so
# purging post-commit closes the re-insert race that a before_destroy
# purge left open.
#
# Inputs are validated, never trusted: the integer chat id re-derives
# every path via the ChatWorkspace helpers, and the recorded
# workspace_path (captured off the row before destroy) is only honored
# when it resolves strictly inside SYRUS_DATA_ROOT.
class ChatSessionCleanupJob < ApplicationJob
  queue_as :chat

  def perform(chat_session_id, recorded_workspace_path = nil)
    id = Integer(chat_session_id, exception: false)
    return unless id&.positive?
    # Only clean up after chats that are actually gone. A live chat's
    # workspace must never be deleted out from under it.
    return if ChatSession.exists?(id: id)

    ChatWorkspace.remove_artifacts_for_id!(id, recorded_workspace_path: recorded_workspace_path)
    ChatMessageSearchIndex.delete_for_chat_session(id)
  end
end
