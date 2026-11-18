class PluginDesiredState::RestartStatus
  STUCK_AFTER = 5.minutes

  def initialize(state: PluginDesiredState.current, now: Time.current)
    @state = state
    @now = now
  end

  def as_json
    { revision: state.revision, apply_revision: state.apply_revision,
      apply_requested_at: state.apply_requested_at, processes: processes }
  end

  private

  attr_reader :state, :now

  def processes
    InstanceVersion.fresh.order(:role, :hostname).map do |process|
      process.slice(:hostname, :role, :plugin_set_revision, :plugin_set_digest).merge(
        "restart_state" => restart_state(process)
      )
    end
  end

  def restart_state(process)
    return "current" unless state.apply_revision
    return "restarted" if process.plugin_set_revision.to_i >= state.apply_revision
    return "stuck" if state.apply_requested_at && state.apply_requested_at < now - STUCK_AFTER

    "pending_restart"
  end
end
