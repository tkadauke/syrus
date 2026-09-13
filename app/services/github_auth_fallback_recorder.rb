class GithubAuthFallbackRecorder
  COALESCE_WINDOW = 10.minutes

  def self.record!(repository:, installation:, operation_type:, error:, refresh_attempted:, refresh_succeeded:, run: Thread.current[:syrus_current_run])
    return unless repository && installation
    return if recently_recorded?(
      repository: repository,
      installation: installation,
      operation_type: operation_type,
      error: error,
      refresh_attempted: refresh_attempted,
      refresh_succeeded: refresh_succeeded,
      run: run
    )

    diagnostic = GithubAuthFallbackDiagnostic.create!(
      repository: repository,
      installation: installation,
      run: run,
      github_installation_id: installation.github_installation_id,
      operation_type: operation_type.to_s,
      error_class: error.class.name,
      error_status: error_status(error),
      error_message: error.message.to_s.truncate(1000),
      refresh_attempted: refresh_attempted,
      refresh_succeeded: refresh_succeeded
    )

    message = "github_auth_fallback: using PAT for #{repository.slug} #{operation_type} after App installation #{installation.github_installation_id} failed; " \
              "error=#{diagnostic.error_class} status=#{diagnostic.error_status || 'unknown'}; " \
              "refresh_attempted=#{refresh_attempted} refresh_succeeded=#{refresh_succeeded}"
    Rails.logger.warn("[GithubAuthFallback] #{message}")
    JobLog.append!(run: run, chunk: message, kind: "github_auth_fallback") if run
    diagnostic
  rescue => e
    Rails.logger.warn("[GithubAuthFallback] diagnostic write failed: #{e.class}: #{e.message}")
    nil
  end

  def self.recently_recorded?(repository:, installation:, operation_type:, error:, refresh_attempted:, refresh_succeeded:, run:)
    GithubAuthFallbackDiagnostic
      .where(repository: repository, installation: installation, run: run)
      .where(operation_type: operation_type.to_s)
      .where(error_class: error.class.name, error_status: error_status(error))
      .where(refresh_attempted: refresh_attempted, refresh_succeeded: refresh_succeeded)
      .where("created_at >= ?", COALESCE_WINDOW.ago)
      .exists?
  end
  private_class_method :recently_recorded?

  def self.error_status(error)
    return error.response_status if error.respond_to?(:response_status) && error.response_status.present?
    return error.status if error.respond_to?(:status) && error.status.present?

    response = error.respond_to?(:response) ? error.response : nil
    return response[:status] if response.is_a?(Hash) && response[:status].present?
    return response.status if response.respond_to?(:status)
    return 401 if error.is_a?(Octokit::Unauthorized)
    return 404 if error.is_a?(Octokit::NotFound)

    nil
  end
  private_class_method :error_status
end
