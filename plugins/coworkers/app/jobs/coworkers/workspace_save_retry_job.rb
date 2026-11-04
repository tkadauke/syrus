module Coworkers
  class WorkspaceSaveRetryJob < ApplicationJob
    queue_as :chat

    discard_on ActiveRecord::RecordNotFound

    def perform(coworker_chat_id)
      link = Coworkers::Chat.includes(:chat_session).find(coworker_chat_id)
      state = Coworkers::UnsavedWorkspace.new(link.chat_session)
      state.begin_retry!
      return unless link.reload.unsaved_workspace_branch?

      Coworkers::ChatWorkspaceLifecycle.new(link.chat_session).finalize!(schedule_background: false)
      state.schedule_retry! if link.reload.unsaved_workspace_branch? && link.unsaved_workspace_failure_kind == "transient"
    end
  end
end
