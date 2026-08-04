class BranchDivergenceResolutionEvidence
  def self.for(job:, workflow:) = new(job: job, workflow: workflow).to_h

  def initialize(job:, workflow:)
    @job = job
    @workflow = workflow
  end

  def to_h
    {
      "job_id" => job.id,
      "workflow_id" => workflow.id,
      "branch" => branch,
      "remote_sha" => current_pr_head_sha.presence || divergence["remote_sha"].presence,
      "workflow_local_sha" => divergence["local_sha"].presence || workspace_value("rev-parse", "HEAD"),
      "base_ref" => base_ref,
      "base_sha" => workspace_value("rev-parse", base_ref).presence || current_pr_base_sha.presence || job.mergeability_base_sha.presence,
      "diff_summary" => diff_summary,
      "branch_divergence" => divergence.slice("remote_sha", "local_sha", "message", "detected_at"),
      "current_pr" => current_pr_payload
    }.compact
  end

  private

  attr_reader :job, :workflow

  def divergence
    @divergence ||= workflow.artifact("branch_divergence").to_h
  end

  def branch
    divergence["branch"].presence || job.branch_name
  end

  def base_ref
    @base_ref ||= WorkflowWorkspace.base_ref_for(job, workflow: workflow)
  end

  def diff_summary
    return { "available" => false, "reason" => "workflow workspace is unavailable" } unless workspace_path.directory?

    {
      "available" => true,
      "stat" => truncated(workspace_value("diff", "--stat", "#{base_ref}...HEAD")),
      "files" => workspace_value("diff", "--name-only", "#{base_ref}...HEAD").to_s.lines.map(&:strip).reject(&:blank?).first(100)
    }
  rescue StandardError => e
    { "available" => false, "reason" => "#{e.class}: #{e.message}" }
  end

  def current_pr_payload
    return unless current_pr

    {
      "number" => pr_number,
      "repository" => pr_repository.slug,
      "head_sha" => current_pr_head_sha,
      "base_sha" => current_pr_base_sha,
      "base_ref" => current_pr_base_ref
    }.compact
  end

  def current_pr_head_sha
    @current_pr_head_sha ||= current_pr&.head&.sha.to_s.presence ||
      job.mergeability_head_sha.presence ||
      job.pr_checks_sha.presence
  end

  def current_pr_base_sha
    @current_pr_base_sha ||= MergeabilityRecorder.base_sha(current_pr).presence if current_pr
  end

  def current_pr_base_ref
    @current_pr_base_ref ||= MergeabilityRecorder.base_ref(current_pr).presence if current_pr
  end

  def current_pr
    @current_pr ||= begin
      return nil if pr_number.blank?

      GithubClient.for(repository: pr_repository, user: job.user)
        .pull_request(pr_repository.slug, pr_number, bypass_cache: true)
    rescue StandardError => e
      Rails.logger.warn("[BranchDivergenceResolutionEvidence] failed to fetch PR for Job ##{job.id}: #{e.class}: #{e.message}")
      nil
    end
  end

  def pr_number
    @pr_number ||= job.pr_number.presence || job.external_pr_number.presence
  end

  def pr_repository
    @pr_repository ||= job.effective_pr_repository
  end

  def workspace_value(*args)
    return nil unless workspace_path.directory?

    git.run(*args, chdir: workspace_path.to_s).strip
  rescue GitRunner::GitError
    nil
  end

  def workspace_path
    @workspace_path ||= WorkflowWorkspace.path_for(workflow)
  end

  def git
    @git ||= GitRunner.new
  end

  def truncated(text)
    SyrusChatMcp.truncate_text(text.to_s, 4.kilobytes)
  end
end
