class JobDetachPlan
  def self.for(job, destination_base:)
    new(job, destination_base: destination_base).to_h
  end

  def initialize(job, destination_base:)
    @job = job
    @destination_base = destination_base.to_s.strip
  end

  def to_h
    client = GithubClient.for(repository: job.repository, user: job.user)
    pr = client.pull_request(job.repository.slug, job.pr_number, bypass_cache: true)
    live_base = MergeabilityRecorder.base_ref(pr)
    head_sha = client.branch_head_sha(job.repository.slug, job.branch_name)
    content = RepositoryContent.for(job.repository)
    history = content.history(base: content.resolve(live_base), head: content.resolve(head_sha))
    changes = content.changes(base: content.resolve(live_base), head: content.resolve(head_sha), patch: true)

    {
      "job_id" => job.id,
      "slug" => job.slug,
      "workflow_ids" => job.workflows.order(:id).pluck(:id),
      "pr_number" => job.pr_number,
      "branch_name" => job.branch_name,
      "current_branch_head" => head_sha,
      "live_pr_base" => live_base,
      "inferred_parent_job_id" => job.parent_job_id,
      "destination_base" => destination_base,
      "commits_to_preserve" => history.commits.map { |commit| { "sha" => commit.sha, "message" => commit.message } },
      "patches_to_preserve" => changes.map { |change| { "path" => change.path, "status" => change.status, "patch" => change.patch } },
      "expected_topology" => {
        "parent_job_id" => nil,
        "pr_base" => destination_base,
        "branch" => job.branch_name
      }
    }
  end

  private

  attr_reader :job, :destination_base
end
