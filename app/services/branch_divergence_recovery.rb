class BranchDivergenceRecovery
  Result = Data.define(:error) do
    def success? = error.blank?
  end

  def self.force_push!(...) = new(...).force_push!
  def self.mark_force_push_pending!(...) = new(...).mark_force_push_pending!
  def self.record_failure!(workflow:, user:, message:) = new(workflow: workflow, user: user).record_failure!(message: message)
  def self.discard!(...) = new(...).discard!
  def self.discard_superseded!(workflow:) = new(workflow: workflow, user: nil).discard_superseded!

  def initialize(workflow:, user:)
    @workflow = workflow
    @job = workflow.job
    @user = user
  end

  def force_push!
    return failure("No branch divergence was recorded for this workflow.") unless divergence
    return failure("Unapprove before replacing the PR branch.") if job.approved? || job.landing?
    return failure("Closed Jobs cannot replace PR branches.") if job.closed?
    return failure("Cannot safely force-push without the observed remote branch SHA.") if remote_sha.blank?
    return failure(workspace_unavailable_message) unless workspace_path.directory?

    GithubAuthenticatedGit.run(repository: job.repository, user: job.user, git: git, operation_type: "git_branch_divergence_force_push") do |url|
      git.run(
        "push",
        "--force-with-lease=refs/heads/#{branch}:#{remote_sha}",
        url,
        "HEAD:refs/heads/#{branch}",
        chdir: workspace_path.to_s
      )
    end
    record_recovery!("force_pushed")
    restore_job_to_implemented_if_possible!
    Result.new(error: nil)
  rescue GitRunner::GitError => e
    failure("Force-push failed: #{e.message}")
  end

  def mark_force_push_pending!
    return failure("No branch divergence was recorded for this workflow.") unless divergence
    return failure("Unapprove before replacing the PR branch.") if job.approved? || job.landing?
    return failure("Closed Jobs cannot replace PR branches.") if job.closed?
    return failure("Cannot safely force-push without the observed remote branch SHA.") if remote_sha.blank?

    write_artifacts!(
      "branch_divergence_recovery_pending" => {
        "action" => "force_push",
        "user_id" => user.id,
        "at" => Time.current.iso8601
      },
      "branch_divergence_recovery_error" => nil
    )
    log!("branch divergence recovery: force_push queued")
    Result.new(error: nil)
  end

  def record_failure!(message:)
    write_artifacts!(
      "branch_divergence_recovery_pending" => nil,
      "branch_divergence_recovery_error" => {
        "message" => message,
        "user_id" => user.id,
        "at" => Time.current.iso8601
      }
    )
    log!("branch divergence recovery failed: #{message}")
    Result.new(error: nil)
  end

  def discard!
    return failure("No branch divergence was recorded for this workflow.") unless divergence

    record_recovery!("discarded")
    restore_job_to_implemented_if_possible!
    Result.new(error: nil)
  end

  def discard_superseded!
    return failure("No branch divergence was recorded for this workflow.") unless divergence
    return failure("Current PR head no longer matches the recorded remote SHA.") unless current_pr_head_matches_recorded_remote?

    record_recovery!("superseded_by_current_pr_branch")
    restore_job_to_implemented_if_possible!
    Result.new(error: nil)
  end

  private

  attr_reader :workflow, :job, :user

  def divergence
    @divergence ||= workflow.artifact("branch_divergence").presence
  end

  def branch
    divergence["branch"].presence || job.branch_name
  end

  def remote_sha
    divergence["remote_sha"].presence
  end

  def current_pr_head_matches_recorded_remote?
    current_pr_head_sha.present? && current_pr_head_sha == remote_sha
  end

  def current_pr_head_sha
    return job[:head_sha].presence if job.has_attribute?(:head_sha)

    job.mergeability_head_sha.presence || job.pr_checks_sha.presence
  end

  def workspace_path
    WorkflowWorkspace.path_for(workflow)
  end

  def git
    @git ||= GitRunner.new
  end

  def record_recovery!(action)
    payload = {
      "action" => action,
      "at" => Time.current.iso8601
    }
    payload["user_id"] = user.id if user

    write_artifacts!(
      "branch_divergence_recovery" => payload,
      "branch_divergence_recovery_pending" => nil,
      "branch_divergence_recovery_error" => nil
    )
    log!("branch divergence recovery: #{action}")
  end

  def write_artifacts!(changes)
    next_artifacts = (workflow.artifacts || {}).dup
    changes.each do |key, value|
      if value.nil?
        next_artifacts.delete(key.to_s)
      else
        next_artifacts[key.to_s] = value
      end
    end
    workflow.update!(artifacts: next_artifacts)
  end

  def log!(message)
    latest_run = workflow.runs.order(:created_at).last
    JobLog.append!(run: latest_run, chunk: message, kind: "system") if latest_run
  end

  def restore_job_to_implemented_if_possible!
    return unless job.failed? && job.pr_number.present?

    StateTransition.with_source("operator") do
      job.retry_after_failure! if job.may_retry_after_failure?
      job.mark_implemented! if job.may_mark_implemented?
      job.save!
    end
  end

  def failure(message)
    Result.new(error: message)
  end

  def workspace_unavailable_message
    if workflow.cleaned_up_at.present?
      "Workflow workspace was already cleaned up - retry from the current PR branch instead."
    else
      "Workflow workspace is not available on this worker - retry from the current PR branch instead."
    end
  end
end
