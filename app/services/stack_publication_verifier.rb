class StackPublicationVerifier
  class Mismatch < StandardError
    attr_reader :evidence

    def initialize(message, evidence:)
      @evidence = evidence
      super(message)
    end
  end

  def initialize(workflow:, repository:, user:, client: nil)
    @workflow = workflow
    @repository = repository
    @user = user
    @client = client || GithubClient.for(repository: repository, user: user)
  end

  def verify!(entries:, expected_heads:, publication_mode:)
    evidence = entries.filter_map do |entry|
      job = Job.find_by(id: entry.fetch("job_id"))
      next if job&.closed?

      verify_entry!(entry, job, expected_heads[entry.fetch("job_id")])
    end

    LandingQueueProcessor.refresh_snapshot!(landing_scope(entries))
    @workflow.set_artifact!("stack_publication", {
      "verified_at" => Time.current.iso8601,
      "status" => "verified",
      "branch_publication" => publication_mode,
      "members" => evidence
    })
    evidence
  end

  private

  def verify_entry!(entry, job, expected_head)
    expected_base = job.effective_base_branch.presence || entry["base_branch"].presence || @repository.default_branch
    pr_number = entry["pr_number"]
    required_evidence = {
      "job_id" => job.id,
      "branch_name" => entry.fetch("branch_name"),
      "pr_number" => pr_number,
      "expected_head_sha" => expected_head,
      "expected_base" => expected_base,
      "expected_parent_job_id" => entry["parent_job_id"]
    }
    if expected_head.blank?
      raise Mismatch.new("#{job.slug}: publication plan did not include an intended head SHA", evidence: required_evidence)
    end
    if pr_number.blank?
      raise Mismatch.new("#{job.slug}: publication plan did not include a pull request number", evidence: required_evidence)
    end

    remote_head = @client.branch_head_sha(@repository.slug, entry.fetch("branch_name"))
    pr = @client.pull_request(@repository.slug, pr_number, bypass_cache: true)
    live_base = MergeabilityRecorder.base_ref(pr)
    live_head = MergeabilityRecorder.head_sha(pr)
    expected_parent_id = entry["parent_job_id"]

    evidence = required_evidence.merge(
      "remote_head_sha" => remote_head,
      "pr_head_sha" => live_head,
      "live_base" => live_base,
      "live_parent_job_id" => job.reload.parent_job_id
    )

    mismatches = []
    mismatches << "remote head is #{remote_head || 'missing'}, expected #{expected_head}" if remote_head != expected_head
    mismatches << "PR head is #{live_head || 'missing'}, expected #{expected_head}" if live_head != expected_head
    mismatches << "PR base is #{live_base || 'missing'}, expected #{expected_base}" if live_base != expected_base
    mismatches << "stack parent is #{job.parent_job_id || 'none'}, expected #{expected_parent_id || 'none'}" if job.parent_job_id != expected_parent_id
    raise Mismatch.new("#{job.slug}: #{mismatches.join('; ')}", evidence: evidence.merge("mismatches" => mismatches)) if mismatches.any?

    MergeabilityRecorder.record_github!(job: job, pr: pr)
    base_sha = MergeabilityRecorder.base_sha(pr)
    if live_head.blank? || base_sha.blank?
      raise Mismatch.new("#{job.slug}: live PR state did not include head and base SHAs", evidence: evidence)
    end

    distance = CommitsBehindCalculator.call(repository: @repository, user: @user, head_sha: live_head, base_sha: base_sha)
    if distance.nil?
      raise Mismatch.new("#{job.slug}: commits-behind could not be recomputed from live state", evidence: evidence.merge("base_sha" => base_sha))
    end
    job.update_columns(commits_behind_base: distance, commits_behind_base_sha: base_sha)
    evidence.merge("base_sha" => base_sha, "commits_behind_base" => distance)
  end

  def landing_scope(entries)
    ids = entries.map { |entry| entry.fetch("job_id") }
    Job.where(id: ids).where(state: %w[approved landing])
  end
end
