module JobExecutionAccessors
  extend ActiveSupport::Concern

  def retry_with_agent_providers
    return [] unless open?
    return [] if any_active_run?
    return [] unless latest_workflow&.retry_as_new_workflow_available?

    configured = user.configured_agent_providers
    return [] unless configured.size > 1

    configured - [ current_run&.agent_provider ]
  end

  def alternate_configured_agent_providers
    user.configured_agent_providers - [ workflow_agent_provider ]
  end

  # The very first Run — the one that created the branch and PR.
  def initial_run
    runs.find_by(trigger_kind: "initial")
  end

  def latest_succeeded_run
    runs.where(state: "succeeded").last
  end

  def head_sha
    runs.where.not(head_sha: [ nil, "" ]).order(:created_at).last&.head_sha
  end
  def any_active_run?
    return runs.any? { |run| run.state.in?(%w[queued running]) } if runs.loaded?

    runs.active.exists?
  end
end
