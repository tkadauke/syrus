class PluginDesiredState::ApplyChanges
  def initialize(actor:, now: Time.current)
    @actor = actor
    @now = now
  end

  def call
    state = PluginDesiredState.current
    state.update!(apply_revision: state.revision, apply_requested_at: now, apply_processes: apply_processes)
    Admin::RestartService.new(actor: actor).request(component: "all", force: true, source: "plugin_apply")
    PluginDesiredState::RestartStatus.new(state: state, now: now).as_json
  end

  private

  attr_reader :actor, :now

  def apply_processes
    InstanceVersion.fresh.where(role: %w[web worker preview]).order(:role, :hostname).map do |process|
      process.slice(:hostname, :role)
    end
  end
end
