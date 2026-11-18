class Coworkers::WorkspaceConflictTimeoutJob < PluginJob
  plugin_name "coworkers"
  queue_as :control_plane
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
