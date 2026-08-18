require "set"

class EpicDependencyPolicy::Linear
  # Validates already-persisted proposals (used at Epic-proposal
  # confirmation time by ChatEpicProposalMaterializer).
  def validate_proposed_child_graph!(proposals)
    proposals = proposals.to_a
    return if proposals.length <= 1

    ids = proposals.map(&:id)
    edges = ChatProposalDependency.where(proposal_id: ids, depends_on_id: ids).pluck(:proposal_id, :depends_on_id)

    self.class.validate_chain!(labels_by_key: proposals.index_by(&:id).transform_values(&:slug), edges: edges)
  end

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
end
