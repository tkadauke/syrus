class Coworkers::ProvisioningCleanup
  UnsafeCleanup = Class.new(StandardError)

  def self.call(...) = new(...).call

  def initialize(attempt, remote_workspace: nil)
    @attempt = attempt
    @remote = remote_workspace || Coworkers::RemoteWorkspace.new(
      owner: attempt.remote_owner, name: attempt.remote_name, user: attempt.owner_user
    )
  end

  def call
    @attempt.with_lock do
      return @attempt if %w[completed cleaned].include?(@attempt.state)
      validate!
      @remote.delete!(@attempt.branch)
      @attempt.update!(state: "cleaned", cleaned_at: Time.current, last_error: nil)
    end
    @attempt
  rescue UnsafeCleanup => error
    fail_terminal!(error)
  rescue StandardError => error
    fail_retryable!(error)
  end

  private

  def validate!
    expected_branch = "coworkers/#{@attempt.handle}"
    raise UnsafeCleanup, "recorded branch does not match the recorded handle" unless @attempt.branch == expected_branch
    if @remote.respond_to?(:repository)
      recorded_remote = [ @attempt.remote_owner.downcase, @attempt.remote_name.downcase ]
      actual_remote = [ @remote.repository.owner.downcase, @remote.repository.name.downcase ]
      raise UnsafeCleanup, "cleanup remote does not match the recorded remote" unless actual_remote == recorded_remote
    end
    if Coworkers::Coworker.where(owner_user: @attempt.owner_user, handle: @attempt.handle).exists?
      raise UnsafeCleanup, "the branch is owned by a completed coworker"
    end
    current = @remote.branch_sha(@attempt.branch)
    return if current.nil? # An already-absent ref is a successful idempotent cleanup.
    raise UnsafeCleanup, "the remote ref no longer points to the seeded commit" unless current == @attempt.expected_seeded_commit
  end

  def fail_terminal!(error)
    @attempt.update!(state: "manual_attention", manual_attention_at: Time.current, last_error: redacted(error))
    @attempt
  end

  def fail_retryable!(error)
    @attempt.update!(state: "cleanup_pending", retry_count: @attempt.retry_count + 1, last_error: redacted(error))
    raise if @attempt.retry_count < Coworkers::ProvisioningCleanupJob::MAX_ATTEMPTS
    @attempt.update!(state: "manual_attention", manual_attention_at: Time.current)
    @attempt
  end

  def redacted(error) = GitRunner.redact("#{error.class}: #{error.message}")
end
