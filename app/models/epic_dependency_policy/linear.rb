require "set"

class EpicDependencyPolicy::Linear
  PROPOSAL_KEY_PREFIX = "proposal:"
  JOB_KEY_PREFIX = "job:"

  def self.proposal_key(id) = "#{PROPOSAL_KEY_PREFIX}#{id}"
  def self.job_key(id) = "#{JOB_KEY_PREFIX}#{id}"

  # Validates an arbitrary dependent -> dependency edge list keyed by
  # whatever identity the caller has on hand (DB id, proposal slug, ...).
  # Shared so tool-level (pre-persistence) and materializer-level
  # (post-persistence) callers enforce the exact same "single chain" rule.
  # `edges` is an array of [dependent_key, dependency_key] pairs.
  def self.validate_chain!(labels_by_key:, edges:)
    keys = labels_by_key.keys
    return if keys.length <= 1

    reachable = keys.to_h { |key| [ key, Set.new ] }
    edges.each do |dependent_key, dependency_key|
      reachable.fetch(dependency_key) << dependent_key
    end

    keys.each do |key|
      queue = reachable.fetch(key).to_a
      until queue.empty?
        reachable_key = queue.shift
        reachable.fetch(reachable_key).each do |next_key|
          next if reachable.fetch(key).include?(next_key)

          reachable.fetch(key) << next_key
          queue << next_key
        end
      end
    end

    unordered = keys.combination(2).find do |left_key, right_key|
      !reachable.fetch(left_key).include?(right_key) && !reachable.fetch(right_key).include?(left_key)
    end
    return unless unordered

    labels = unordered.map { |key| labels_by_key.fetch(key) }
    raise ArgumentError,
          "Epic child dependency graph must be a single chain; child slugs are unordered or branching: #{labels.join(', ')}. " \
          "Add sibling depends_on edges to make one chain."
  end

  # Validates already-persisted proposals (used at Epic-proposal
  # confirmation time by ChatEpicProposalMaterializer). When `epic` is
  # given, that Epic's already-existing child Jobs (and the same-epic
  # JobDependency edges between them) are folded into the same graph, so
  # new proposals that don't chain onto an Epic's existing tail are
  # rejected too — not just proposals that branch among themselves.
  def validate_proposed_child_graph!(proposals, epic: nil)
    proposals = proposals.to_a
    return if proposals.length <= 1 && !epic&.jobs&.exists?

    ids = proposals.map(&:id)
    labels_by_key = proposals.index_by(&:id).transform_values(&:slug).transform_keys { |id| self.class.proposal_key(id) }
    edges = ChatProposalDependency.where(proposal_id: ids, depends_on_id: ids)
                                   .pluck(:proposal_id, :depends_on_id)
                                   .map { |dependent_id, dependency_id| [ self.class.proposal_key(dependent_id), self.class.proposal_key(dependency_id) ] }

    if epic
      proposals.each do |proposal|
        Array(proposal.depends_on_job_ids).each do |job_id|
          next unless epic.jobs.exists?(id: job_id)

          edges << [ self.class.proposal_key(proposal.id), self.class.job_key(job_id) ]
        end
      end
      merge_epic_jobs!(labels_by_key, edges, epic)
    end

    self.class.validate_chain!(labels_by_key: labels_by_key, edges: edges)
  end

  private

  def merge_epic_jobs!(labels_by_key, edges, epic)
    epic.jobs.find_each { |job| labels_by_key[self.class.job_key(job.id)] = job.slug }
    JobDependency.where(job_id: epic.jobs.select(:id), depends_on_job_id: epic.jobs.select(:id))
                 .pluck(:job_id, :depends_on_job_id)
                 .each { |dependent_id, dependency_id| edges << [ self.class.job_key(dependent_id), self.class.job_key(dependency_id) ] }
  end
end
