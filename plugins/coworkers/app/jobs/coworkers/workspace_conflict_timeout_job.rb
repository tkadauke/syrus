class Coworkers::WorkspaceConflictTimeoutJob < ApplicationJob
  queue_as :control_plane
  retry_on StandardError, wait: :polynomially_longer, attempts: 5
  discard_on ActiveRecord::RecordNotFound

  def perform(conflict_id)
    conflict = Coworkers::WorkspaceConflict.find(conflict_id)
    lifecycle = Coworkers::ChatWorkspaceLifecycle.new(
      conflict.chat_session,
      repository: conflict.repository,
      remote_url: conflict.repository.remote_url
    )
    lifecycle.expire_conflict!(conflict)
  end
end
