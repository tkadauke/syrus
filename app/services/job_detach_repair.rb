class JobDetachRepair
  Result = Data.define(:status, :workflow, :evidence)

  def self.call(job:, destination_base:, reason:, requested_by:, former_parent_id:, former_parent_head:, owned_patch_base_sha:, confirmed_head:, auto_rebase: nil)
    new(job: job, destination_base: destination_base, reason: reason, requested_by: requested_by,
      former_parent_id: former_parent_id, former_parent_head: former_parent_head,
      owned_patch_base_sha: owned_patch_base_sha, confirmed_head: confirmed_head, auto_rebase: auto_rebase).call
  end

  def self.finalize!(job:, destination_base:, expected_head:, reason:, former_parent_id: nil, client: nil)
    client ||= GithubClient.for(repository: job.repository, user: job.user)
    old_parent = Job.find_by(id: former_parent_id || job.parent_job_id)
    client.update_pull_request_base(job.repository.slug, job.pr_number, base: destination_base)
    ApplicationRecord.transaction do
      job.lock!
      # Without a parent this would match depends_on_job_id IS NULL: every
      # Epic and pending dependency.
      job.dependencies.where(depends_on_job_id: old_parent.id).destroy_all if old_parent
      job.update!(parent_job: nil)
    end
    [ old_parent, job, *job.stack_children ].compact.uniq.each { |member| PrStackFooter.refresh!(member, client: client) }
    evidence = JobDetachPostconditionVerifier.verify!(job: job, destination_base: destination_base, expected_head: expected_head, former_parent_id: old_parent&.id, client: client)
    LandingQueueProcessor.refresh_snapshot!(Job.where(id: job.id).where(state: %w[approved landing]))
    LandingQueueProcessorJob.perform_later
    evidence.merge("reason" => reason, "verified_at" => Time.current.iso8601)
  end

  def initialize(job:, destination_base:, reason:, requested_by:, former_parent_id:, former_parent_head:, owned_patch_base_sha:, confirmed_head:, auto_rebase: nil)
    @job = job
    @destination_base = destination_base
    @reason = reason
    @requested_by = requested_by
    @former_parent_id = former_parent_id
    @former_parent_head = former_parent_head.to_s.presence || raise(ArgumentError, "former_parent_head is required")
    @owned_patch_base_sha = owned_patch_base_sha.to_s.presence || raise(ArgumentError, "owned_patch_base_sha is required")
    @confirmed_head = confirmed_head.to_s.presence || raise(ArgumentError, "confirmed_head is required")
    @auto_rebase = auto_rebase || AutoRebase.new(
      job, base_branch: destination_base, old_base_sha: @owned_patch_base_sha, expected_head_sha: @confirmed_head
    )
  end

  def call
    if @job.parent_job_id != @former_parent_id
      raise ArgumentError, "Stack parent changed after confirmation; dry-run the detach repair again"
    end
    result = @auto_rebase.call
    if result.reason == AutoRebase::ALREADY_LANDED_REASON
      raise ArgumentError, result.note || "Detach publication cannot proceed because the owned patch is already on the destination base"
    end
    if result.succeeded?
      expected_head = result.post_sha || result.pre_sha
      evidence = self.class.finalize!(job: @job, destination_base: @destination_base, expected_head: expected_head, reason: @reason, former_parent_id: @former_parent_id)
      return Result.new(status: "verified", workflow: nil, evidence: evidence.merge("rebase" => result.to_h))
    end
    raise ArgumentError, result.note || "Detach publication failed: #{result.reason}" unless result.reason == "conflict"

    workflow = WorkUnits::Launcher.instantiate(
      kind: "rebase",
      job: @job,
      base_branch: @destination_base,
      artifacts: {
        "requested_by" => @requested_by,
        "repair_action" => "detach_job",
        "repair_reason" => @reason,
        "detach_job" => {
          "destination_base" => @destination_base,
          "former_parent_id" => @former_parent_id,
          "former_parent_head" => @former_parent_head,
          "owned_patch_base_sha" => @owned_patch_base_sha,
          "confirmed_head" => @confirmed_head
        }
      }
    )
    WorkUnits::Launcher.start!(workflow)
    Result.new(status: "conflict_fallback", workflow: workflow, evidence: result.to_h)
  end
end
