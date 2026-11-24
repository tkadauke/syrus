class PluginDesiredState::Convergence
  DEFAULT_DIVERGENCE_THRESHOLD = 5.minutes

  def initialize(state: PluginDesiredState.current, now: Time.current, threshold: nil)
    @state = state
    @now = now
    @threshold = threshold || ENV.fetch("SYRUS_PLUGIN_DIVERGENCE_THRESHOLD_SECONDS", DEFAULT_DIVERGENCE_THRESHOLD.to_i).to_i.seconds
  end

  def as_json
    {
      desired_revision: state.revision,
      divergence_threshold_seconds: threshold.to_i,
      processes: process_rows
    }
  end

  def prolonged_divergence?
    process_rows.any? { |row| row[:diverged_too_long] }
  end

  private

  attr_reader :state, :now, :threshold

  def process_rows
    @process_rows ||= cohort.map { |process| serialize(process) }.sort_by { |row| [ row[:role], row[:hostname] ] }
  end

  def cohort
    live = InstanceVersion.running.index_by { |process| [ process.hostname, process.role ] }
    recorded_by_key = recorded_processes.index_by { |process| [ process.hostname, process.role ] }
    Array(state.apply_processes).each do |recorded_process|
      key = [ value(recorded_process, :hostname), value(recorded_process, :role) ]
      live[key] ||= recorded_by_key[key] || recorded_process
    end
    live.values
  end

  def recorded_processes
    cohort = Array(state.apply_processes)
    return InstanceVersion.none if cohort.empty?

    InstanceVersion.where(
      hostname: cohort.filter_map { |process| value(process, :hostname) }.uniq,
      role: cohort.filter_map { |process| value(process, :role) }.uniq
    )
  end

  def serialize(process)
    heartbeat = value(process, :last_heartbeat_at)&.to_time
    revision = value(process, :plugin_set_revision)
    status = convergence_state(process, heartbeat, revision)
    divergent_since = divergence_started_at(process, heartbeat, status)
    {
      hostname: value(process, :hostname), role: value(process, :role), state: status,
      running_revision: revision, running_digest: value(process, :plugin_set_digest),
      last_heartbeat_at: heartbeat&.iso8601,
      diverged_since: divergent_since&.iso8601,
      diverged_too_long: status != "converged" && divergent_since.present? && divergent_since <= now - threshold,
      plugins: plugin_rows(process)
    }
  end

  def convergence_state(process, heartbeat, revision)
    return "converged" if enabled_installations.empty?
    return "unreachable" if heartbeat.blank? || heartbeat < now - InstanceVersion::HEARTBEAT_STALE_THRESHOLD
    return "converged" if value(process, :plugin_set_digest).present? && value(process, :plugin_set_digest) == desired_digest(value(process, :role))
    return "ahead" if revision.present? && revision.to_i > state.revision
    return "pending_restart" if state.apply_revision == state.revision && state.apply_requested_at.present? && revision.to_i < state.revision

    "behind"
  end

  def divergence_started_at(process, heartbeat, status)
    return nil if status == "converged"
    candidates = [ state.updated_at, value(process, :started_at)&.to_time ]
    candidates << heartbeat + InstanceVersion::HEARTBEAT_STALE_THRESHOLD if status == "unreachable" && heartbeat
    candidates.compact.max
  end

  def plugin_rows(process)
    running = value(process, :plugin_set_details).to_h.fetch("plugins", []).index_by { |plugin| plugin["name"] }
    installations.map do |installation|
      plugin = running[installation.plugin_name]
      {
        name: installation.plugin_name,
        desired_version: installation.plugin_release.version,
        running_version: plugin&.dig("version"),
        state: plugin&.dig("state") || (installation.fleet_quarantined ? "quarantined" : "missing"),
        reasons: plugin&.dig("reasons") || []
      }
    end
  end

  def desired_digest(role)
    @desired_digests ||= {}
    @desired_digests[role] ||= Digest::SHA256.hexdigest(JSON.generate(desired_entries(role)))
  end

  def desired_entries(role)
    enabled_installations.filter_map do |installation|
      next if installation.fleet_quarantined?
      next if installation.roles.any? && !installation.roles.include?(role)
      release = installation.plugin_release
      { "name" => installation.plugin_name, "version" => release.version, "digest" => release.content_digest, "size" => release.size_bytes }
    end.sort_by { |entry| entry.fetch("name") }
  end

  def installations
    @installations ||= PluginInstallation.includes(:plugin_release).order(:plugin_name).to_a
  end

  def enabled_installations
    @enabled_installations ||= installations.select { |installation| installation.enabled_for_sync? && installation.plugin_release.source != "bundled" }
  end

  def value(process, attribute)
    return process.public_send(attribute) if process.respond_to?(attribute)
    process[attribute.to_s] || process[attribute]
  end
end
