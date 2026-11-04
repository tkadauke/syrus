module Coworkers
  class WorkspaceSaveRetryJob < ApplicationJob
    queue_as :chat

    discard_on ActiveRecord::RecordNotFound

    def perform(coworker_chat_id, token)
      link = Coworkers::Chat.includes(:chat_session).find(coworker_chat_id)
      state = Coworkers::UnsavedWorkspace.new(link.chat_session)
      return unless state.begin_retry!(token)
      return unless link.reload.unsaved_workspace_branch?

      Coworkers::WorkspaceSaveRetry.for(link.unsaved_workspace_operation).perform(link)
      state.schedule_retry! if link.reload.unsaved_workspace_branch? && link.unsaved_workspace_failure_kind == "transient"
    end
  end
end
