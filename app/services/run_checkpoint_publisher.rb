class RunCheckpointPublisher
  MAX_PUBLISH_ATTEMPTS = 3
  RETRY_DELAYS = [ 0.25, 1.0 ].freeze
  TRANSIENT_GIT_FAILURE = /(?:internal server error|http 5\d\d|http 429|too many requests|timed? out|timeout|connection (?:reset|refused)|could not resolve host|temporary failure|remote end hung up|service unavailable)/i
  MUTATION_STEP_KINDS = %w[
    implement
    respond
    analyze_and_fix
    run_skill
    manual_agentic_run
    merge_train_reconcile
    landing_fix
    push_agent_rebase
    agent_rebase
    stack_agent_rebase
    merge_train_agent_rebase
    pr_open
  ].freeze

  def self.publish!(...) = new(...).publish!

  def initialize(run:, workspace:, git: nil, log: nil, sleeper: Kernel)
    @run = run
    @workspace = workspace
    @git = git || GitRunner.new
    @log = log
    @sleeper = sleeper
  end

  def publish!
    return nil unless eligible?
    return suppressed_during_push_protection_repair if push_protection_repair_active?

    checkpoint = RunCheckpoint.find_or_initialize_by(run_id: run.id)
    checkpoint.assign_attributes(checkpoint_attributes.merge(status: "pending", error_message: nil))
    checkpoint.save!

    publish_ref_with_retry!(checkpoint)
    PushProtection::Ledger.for(run.workflow).record_accepted!(checkpoint.commit_sha)
    checkpoint.update!(status: "published", published_at: Time.current, error_message: nil)
    log("checkpoint: published #{checkpoint.remote_ref} at #{checkpoint.commit_sha.first(12)}", kind: "system")
    checkpoint
  rescue StandardError => e
    checkpoint&.update(status: "failed", error_message: "#{e.class}: #{e.message}") if checkpoint&.persisted?
    Rails.logger.warn("[RunCheckpointPublisher] failed for Run ##{run.id}: #{e.class}: #{e.message}")
    log("checkpoint: failed to publish durable checkpoint #{checkpoint&.remote_ref}: #{e.class}: #{e.message}; preserving the live workspace until an equivalent source snapshot is durable", kind: "system")
    nil
  end

  private

  attr_reader :run, :workspace, :git

  def publish_ref_with_retry!(checkpoint)
    attempt = 0
    begin
      attempt += 1
      publish_ref!(checkpoint)
    rescue GitRunner::GitError => e
      raise unless e.message.match?(TRANSIENT_GIT_FAILURE) && attempt < MAX_PUBLISH_ATTEMPTS

      delay = RETRY_DELAYS.fetch(attempt - 1)
      log("checkpoint: transient failure publishing #{checkpoint.remote_ref} (#{e.class}, attempt #{attempt}/#{MAX_PUBLISH_ATTEMPTS}); retrying in #{delay}s", kind: "system")
      @sleeper.sleep(delay)
      retry
    end
  end

  # A checkpoint ref would republish the rejected ancestry to GitHub. Work stays
  # in the workspace until clean history has been reconstructed.
  def push_protection_repair_active?
    PushProtection::Ledger.for(run.workflow).repair_active?
  end

  def suppressed_during_push_protection_repair
    log("checkpoint: suppressed while a GitHub push-protection repair is in progress", kind: "system")
    nil
  end

  def eligible?
    run.step&.kind.in?(MUTATION_STEP_KINDS) &&
      run.head_sha.present? &&
      run.workflow.present? &&
      !run.job.main_grader?
  end

  def checkpoint_attributes
    {
      workflow: run.workflow,
      step: run.step,
      job: run.job,
      repository: run.job.repository,
      user: run.user,
      step_kind: run.step.kind,
      commit_sha: run.head_sha,
      base_sha: run.base_sha,
      remote_ref: RunCheckpoint.remote_ref_for(run)
    }
  end

  def publish_ref!(checkpoint)
    existing_sha = remote_ref_sha(checkpoint.remote_ref)
    if existing_sha.present?
      raise "checkpoint ref #{checkpoint.remote_ref} already points at #{existing_sha}, expected #{checkpoint.commit_sha}" unless existing_sha == checkpoint.commit_sha

      return
    end

    authenticated_git("git_checkpoint_push") do |url|
      git.run("push", url, "#{checkpoint.commit_sha}:#{checkpoint.remote_ref}", chdir: workspace.path.to_s, env: env)
    end
  rescue GitRunner::GitError => e
    existing_sha = remote_ref_sha(checkpoint.remote_ref)
    return if existing_sha == checkpoint.commit_sha

    raise e
  end

  def remote_ref_sha(ref)
    output = authenticated_git("git_checkpoint_ls_remote") do |url|
      git.run("ls-remote", url, ref, chdir: workspace.path.to_s, env: env)
    end
    output.to_s.lines.first.to_s.split(/\s+/).first.presence
  end

  def authenticated_git(operation_type, &block)
    GithubAuthenticatedGit.run(
      repository: run.job.repository,
      user: run.user,
      git: git,
      operation_type: operation_type,
      log: method(:log),
      &block
    )
  end

  def env
    { "GIT_TERMINAL_PROMPT" => "0" }
  end

  def log(message, **kwargs)
    @log&.call(message, **kwargs)
  end
end
