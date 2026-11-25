class JobDetachPostconditionVerifier
  class Mismatch < StandardError; end

  def self.verify!(job:, destination_base:, expected_head:, former_parent_id: nil, client: nil)
    new(job: job, destination_base: destination_base, expected_head: expected_head, former_parent_id: former_parent_id, client: client).verify!
  end

  def initialize(job:, destination_base:, expected_head:, former_parent_id: nil, client: nil)
    @job = job
    @destination_base = destination_base
    @expected_head = expected_head
    @former_parent_id = former_parent_id
    @client = client || GithubClient.for(repository: job.repository, user: job.user)
  end

  def verify!
    remote_head = @client.branch_head_sha(@job.repository.slug, @job.branch_name)
    pr = @client.pull_request(@job.repository.slug, @job.pr_number, bypass_cache: true)
    live_base = MergeabilityRecorder.base_ref(pr)
    live_head = MergeabilityRecorder.head_sha(pr)
    mismatches = []
    mismatches << "remote head is #{remote_head || 'missing'}, expected #{@expected_head}" if remote_head != @expected_head
    mismatches << "PR head is #{live_head || 'missing'}, expected #{@expected_head}" if live_head != @expected_head
    mismatches << "PR base is #{live_base || 'missing'}, expected #{@destination_base}" if live_base != @destination_base
    mismatches << "stack parent is #{@job.reload.parent_job_id}, expected none" if @job.parent_job_id.present?
    if @former_parent_id && @job.dependencies.where(depends_on_job_id: @former_parent_id).exists?
      mismatches << "explicit dependency on former parent #{@former_parent_id} still exists"
    end
    raise Mismatch, mismatches.join("; ") if mismatches.any?

    { "remote_head" => remote_head, "pr_head" => live_head, "pr_base" => live_base, "parent_job_id" => nil }
  end
end
