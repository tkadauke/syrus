class PluginDesiredState::ApplyChanges
  def initialize(actor:, now: Time.current)
    @actor = actor
    @now = now
  end

  def call
    state = PluginDesiredState.current
    state.update!(apply_revision: state.revision, apply_requested_at: now)
    Admin::RestartService.new(actor: actor).request(component: "all", force: true, source: "plugin_apply")
    PluginDesiredState::RestartStatus.new(state: state, now: now).as_json
  end

  private

  attr_reader :actor, :now
end
