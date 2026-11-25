# Splices a new segment of Jobs into the middle of an Epic's linear chain.
#
# An Epic's child Jobs form one chain (JobDependency#linear_chain_within_epic
# rejects any single edge that forks or merges it), so inserting between A and
# B cannot be expressed as independent single-edge writes. This service owns
# the whole rewrite instead: it validates the *end state* with
# EpicDependencyPolicy::Linear and orders the writes so that no individual
# write is a fork or a merge, which leaves the model validation untouched for
# every other caller:
#
#   1. the new segment is chained among itself (the caller does that);
#   2. the downstream Job's existing edge into the anchor is re-pointed at the
#      segment's tail (an in-place update, so its satisfaction mode and stage
#      requirement are preserved) -- the tail has no dependents yet;
#   3. the segment's head is chained onto the anchor, which no longer has a
#      downstream Job.
#
# Rule for running work: the downstream Job's stack parent changes, so the
# splice is rejected unless that Job has not started -- it must be in a
# pre-execution state and have no running Run. A started Job is never
# silently re-parented.
class EpicChainSplice
  class Rejected < ArgumentError; end

  NOT_STARTED_STATES = %w[backlog needs_triage triaging blocked_by_epic queued].freeze

  Plan = Struct.new(:epic, :anchor, :downstream_edge, keyword_init: true) do
    def downstream_job = downstream_edge&.job
  end

  # Resolves and validates the anchor at proposal or confirmation time.
  def self.plan!(epic:, anchor_job_id:)
    raise Rejected, "insert_after_job_id requires a target Epic" if epic.nil?

    anchor = epic.jobs.find_by(id: anchor_job_id)
    raise Rejected, "insert_after_job_id #{anchor_job_id} is not a Job in #{epic.slug}" unless anchor

    edges = JobDependency.where(depends_on_job_id: anchor.id)
                         .joins(:job)
                         .where(jobs: { epic_id: epic.id })
                         .includes(:job)
                         .to_a
    if edges.length > 1
      raise Rejected, "#{anchor.slug} already has more than one downstream Job in #{epic.slug}; fix the Epic's chain before inserting after it"
    end

    downstream = edges.first&.job
    if downstream && !not_started?(downstream)
      raise Rejected,
            "Cannot insert after #{anchor.slug}: the next Job in the chain, #{downstream.slug}, has already started " \
            "(state #{downstream.state}) and would be re-parented. Insert after #{downstream.slug} or a later Job instead."
    end

    Plan.new(epic: epic, anchor: anchor, downstream_edge: edges.first)
  end

  def self.not_started?(job)
    job.state.in?(NOT_STARTED_STATES) && !job.runs.where(state: "running").exists?
  end

  # Orders a batch of new Jobs into the chain they form among themselves.
  # `upstream_by_key` maps each key to the batch keys it depends on. Raises
  # ArgumentError unless the batch is exactly one chain.
  def self.order_segment(keys, upstream_by_key)
    keys = keys.to_a
    in_batch = ->(key) { Array(upstream_by_key[key]) & keys }
    if keys.any? { |key| in_batch.call(key).length > 1 }
      raise ArgumentError, "Jobs inserted into an Epic must form a single chain; one depends on more than one sibling"
    end

    heads = keys.select { |key| in_batch.call(key).empty? }
    raise ArgumentError, "Jobs inserted into an Epic must form a single chain with exactly one first Job" unless heads.length == 1

    ordered = [ heads.first ]
    while (following = keys.select { |key| in_batch.call(key) == [ ordered.last ] }).any?
      raise ArgumentError, "Jobs inserted into an Epic must form a single chain; #{ordered.last} has several dependents" if following.length > 1

      ordered << following.first
    end
    raise ArgumentError, "Jobs inserted into an Epic must form a single chain" unless ordered.length == keys.length

    ordered
  end

  # Validates the chain the Epic would have after the splice. `new_keys` are
  # [key, label] pairs for the inserted segment, head first. Raises
  # ArgumentError (Linear.validate_chain!) when the end state is not one chain.
  # `already_created_ids` names inserted Jobs that already exist in the Epic
  # (the single-Job confirmation path creates the Job before splicing); they
  # are represented by `new_keys`, not as pre-existing Epic members.
  def self.validate_final_chain!(plan, new_keys, already_created_ids: [])
    epic = plan.epic
    existing_ids = epic.jobs.where.not(id: already_created_ids).pluck(:id)
    labels_by_key = epic.jobs.where(id: existing_ids).to_h { |job| [ EpicDependencyPolicy::Linear.job_key(job.id), job.slug ] }
    new_keys.each { |key, label| labels_by_key[key] = label }

    edges = JobDependency.where(job_id: existing_ids, depends_on_job_id: existing_ids)
                         .pluck(:id, :job_id, :depends_on_job_id)
                         .reject { |id, _, _| id == plan.downstream_edge&.id }
                         .map { |_, job_id, dependency_id| [ EpicDependencyPolicy::Linear.job_key(job_id), EpicDependencyPolicy::Linear.job_key(dependency_id) ] }
    head_key = new_keys.first.first
    tail_key = new_keys.last.first
    new_keys.each_cons(2) { |(upstream, _), (downstream, _)| edges << [ downstream, upstream ] }
    edges << [ head_key, EpicDependencyPolicy::Linear.job_key(plan.anchor.id) ]
    edges << [ EpicDependencyPolicy::Linear.job_key(plan.downstream_job.id), tail_key ] if plan.downstream_job

    EpicDependencyPolicy::Linear.validate_chain!(labels_by_key: labels_by_key, edges: edges)
  end

  # Performs steps 2 and 3. Call inside the transaction that created the Jobs
  # and chained them among themselves. Re-validates against the live Epic so a
  # change between proposal and confirmation is caught.
  def self.apply!(epic:, anchor_job_id:, head_job:, tail_job:, user:)
    plan = plan!(epic: epic, anchor_job_id: anchor_job_id)
    edge = plan.downstream_edge
    edge&.update!(depends_on_job: tail_job)
    JobDependency.create!(
      job: head_job,
      depends_on_job: plan.anchor,
      source: "manual",
      created_by_user: user
    )
    plan
  end
end
