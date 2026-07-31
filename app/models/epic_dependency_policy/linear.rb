require "set"

class EpicDependencyPolicy::Linear < EpicDependencyPolicy::Base
  def resolve(epic)
    "linear"
  end

  def validate_proposed_child_graph!(proposals)
    proposals = proposals.to_a
    return if proposals.length <= 1

    ids = proposals.map(&:id)
    slugs_by_id = proposals.index_by(&:id).transform_values(&:slug)
    reachable = ids.to_h { |id| [ id, Set.new ] }

    ChatProposalDependency.where(proposal_id: ids, depends_on_id: ids).pluck(:proposal_id, :depends_on_id).each do |proposal_id, depends_on_id|
      reachable.fetch(depends_on_id) << proposal_id
    end

    ids.each do |id|
      queue = reachable.fetch(id).to_a
      until queue.empty?
        reachable_id = queue.shift
        reachable.fetch(reachable_id).each do |next_id|
          next if reachable.fetch(id).include?(next_id)

          reachable.fetch(id) << next_id
          queue << next_id
        end
      end
    end

    unordered = ids.combination(2).find do |left_id, right_id|
      !reachable.fetch(left_id).include?(right_id) && !reachable.fetch(right_id).include?(left_id)
    end
    return unless unordered

    slugs = unordered.map { |id| slugs_by_id.fetch(id) }
    raise ArgumentError,
          "Epic child dependency graph must be a single chain under linear policy; child slugs are unordered or branching: #{slugs.join(', ')}. " \
          "Add sibling depends_on edges to make one chain, or set nonlinear_dependency_override only when the operator explicitly requested nonlinear execution."
  end

  def reconciliation_dependency_jobs(_epic, sibling_jobs)
    sibling_jobs = sibling_jobs.to_a
    sibling_ids = sibling_jobs.map(&:id)
    edges = JobDependency.resolved.where(job_id: sibling_ids, depends_on_job_id: sibling_ids).pluck(:job_id, :depends_on_job_id)
    reachable = sibling_ids.to_h { |id| [ id, Set.new ] }

    edges.each do |job_id, depends_on_job_id|
      reachable.fetch(depends_on_job_id) << job_id
    end

    sibling_ids.each do |id|
      queue = reachable.fetch(id).to_a
      until queue.empty?
        reachable_id = queue.shift
        reachable.fetch(reachable_id).each do |next_id|
          next if reachable.fetch(id).include?(next_id)

          reachable.fetch(id) << next_id
          queue << next_id
        end
      end
    end

    unordered = sibling_ids.combination(2).find do |left_id, right_id|
      !reachable.fetch(left_id).include?(right_id) && !reachable.fetch(right_id).include?(left_id)
    end
    raise ArgumentError, "linear Epic reconciliation requires one linear child Job chain" if unordered

    referenced_ids = edges.map(&:second).uniq
    leaf_jobs = sibling_jobs.reject { |job| referenced_ids.include?(job.id) }

    if leaf_jobs.one?
      leaf_jobs
    else
      raise ArgumentError,
            "linear Epic reconciliation requires one linear child Job chain; found #{leaf_jobs.length} final children"
    end
  end
end
