class VisualReviewRuntimeSession
  attr_reader :runtime_session

  def initialize(run:, target:)
    @run = run
    @target = target
  end

  def start!
    provider_class = RuntimeSessionProviders.for(target.provider)
    options = start_options
    @runtime_session = RuntimeSession.create!(
      repository: run.job.repository,
      job: run.job,
      workflow: run.workflow,
      run: run,
      workspace_ref: target.workspace_path,
      provider_key: provider_class.provider_key,
      display_name: target.name.presence || provider_class.display_name,
      capabilities: provider_class.capabilities(run.job.repository, options),
      primary: !run.runtime_sessions.active.exists?,
      state: "starting",
      metadata: { "visual_review_target" => target.to_h }
    )

    provider = provider_class.new
    result = provider.start_session(target.workspace_path, options.merge(runtime_session: runtime_session))
    runtime_session.update!(state: "running", metadata: runtime_session.metadata.merge(result.to_h.deep_stringify_keys))
    provider_call!(provider.build_or_reload(runtime_session.id, target.build), "build") if target.build.present?
    provider_call!(provider.launch(runtime_session.id, target.launch), "launch") if target.launch.present?
    runtime_session
  rescue StandardError => e
    runtime_session&.update!(state: "failed", last_error: "#{e.class}: #{e.message}")
    raise
  end

  def stop!
    return unless runtime_session&.persisted?

    runtime_session.runtime_control_leases.active.find_each(&:release!)
    unless runtime_session.stopped?
      runtime_session.update!(state: "stopping") unless runtime_session.failed?
      RuntimeSessionProviders.for(runtime_session.provider_key).new.stop_session(runtime_session.id)
      runtime_session.update!(state: "stopped")
    end
  rescue StandardError => e
    runtime_session&.update!(state: "failed", last_error: "#{e.class}: #{e.message}")
    Rails.logger.error("[VisualReviewRuntimeSession] teardown failed for session #{runtime_session&.id}: #{e.class}: #{e.message}")
  end

  private

  attr_reader :run, :target

  def start_options
    dimensions = target.dimensions.to_h
    {
      run: run,
      workflow: run.workflow,
      user: run.user,
      workspace_path: target.workspace_path,
      columns: dimensions["columns"] || dimensions["cols"],
      rows: dimensions["rows"],
      width: dimensions["width"],
      height: dimensions["height"]
    }.compact
  end

  def provider_call!(result, operation)
    error = result.to_h[:error] || result.to_h["error"]
    return result if error.blank?

    message = result.to_h[:message] || result.to_h["message"] || error
    raise "runtime #{operation} failed: #{message}"
  end
end
