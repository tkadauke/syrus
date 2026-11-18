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
    process_rows.sort_by { |process| [ process.fetch("role"), process.fetch("hostname") ] }
  end

  def process_rows
    live = InstanceVersion.fresh.index_by { |process| process_key(process) }
    recorded = recorded_processes.index_by { |process| process_key(process) }
    cohort = Array(state.apply_processes).index_by { |process| process_key(process) }

    (live.keys | cohort.keys).map do |key|
      process = live[key] || recorded[key] || cohort.fetch(key)
      process_payload(process).merge("restart_state" => restart_state(process))
    end
  end

  def recorded_processes
    cohort = Array(state.apply_processes)
    return InstanceVersion.none if cohort.empty?

    InstanceVersion.where(
      hostname: cohort.filter_map { |process| process_value(process, :hostname) }.uniq,
      role: cohort.filter_map { |process| process_value(process, :role) }.uniq
    )
  end

  def process_key(process)
    [ process_value(process, :hostname), process_value(process, :role) ]
  end

  def process_payload(process)
    %i[hostname role plugin_set_revision plugin_set_digest].to_h do |attribute|
      [ attribute.to_s, process_value(process, attribute) ]
    end
  end

  def process_value(process, attribute)
    return process.public_send(attribute) if process.respond_to?(attribute)

    process[attribute.to_s] || process[attribute]
  end

  def restart_state(process)
    return "current" unless state.apply_revision
    return "restarted" if process_value(process, :plugin_set_revision).to_i >= state.apply_revision
    return "stuck" if state.apply_requested_at && state.apply_requested_at < now - STUCK_AFTER

    "pending_restart"
  end
end
