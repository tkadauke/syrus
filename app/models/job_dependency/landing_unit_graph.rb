require "set"

class JobDependency
  # The dependency graph with each Epic contracted to one node.
  #
  # An Epic lands as one unit (its merge train), and the unit waits until
  # every prerequisite outside it has landed. A cycle in this graph is a
  # landing deadlock even when the Job graph alone has none: Epic child A <-
  # outside Job B <- Epic child C makes the train wait for B, and B wait for A,
  # which only lands with the train (formal/SyrusModel/LandingUnitCycle.lean).
  #
  # Nodes are [:epic, id] for an Epic and [:job, id] for a Job outside any
  # Epic. Edges point from the dependent to what it waits for, from resolved
  # JobDependency rows and EpicDependency rows. Edges inside one Epic are its
  # own chain, which linear_chain_within_epic governs, and are left out.
  class LandingUnitGraph
    def self.node_for_job(job) = job.epic_id.present? ? [ :epic, job.epic_id ] : [ :job, job.id ]

    # The path from `from` to `to`, as a list of nodes, or nil when `to` is
    # unreachable. `except` names a JobDependency to leave out (the row being
    # changed, whose old edge is replaced by the new one).
    def path(from, to, except: nil)
      parents = { from => nil }
      queue = [ from ]
      until queue.empty?
        node = queue.shift
        return trace(parents, node) if node == to

        successors(node, except:).each do |successor|
          next if parents.key?(successor)

          parents[successor] = node
          queue << successor
        end
      end
      nil
    end

    private

    def trace(parents, node)
      path = []
      while node
        path.unshift(node)
        node = parents[node]
      end
      path
    end

    def successors(node, except:)
      kind, id = node
      rows = JobDependency.where.not(depends_on_job_id: nil).or(JobDependency.where.not(depends_on_epic_id: nil))
      rows = rows.where.not(id: except) if except
      rows = kind == :epic ? rows.where(job_id: Job.where(epic_id: id).select(:id)) : rows.where(job_id: id)
      targets = rows.pluck(:depends_on_job_id, :depends_on_epic_id)
      if kind == :epic
        targets += EpicDependency.where(epic_id: id).pluck(:depends_on_job_id, :depends_on_epic_id)
      end

      job_epics = Job.where(id: targets.filter_map(&:first)).pluck(:id, :epic_id).to_h
      targets.filter_map do |job_id, epic_id|
        target = epic_id ? [ :epic, epic_id ] : (job_epics[job_id] ? [ :epic, job_epics[job_id] ] : [ :job, job_id ])
        target unless target == node
      end.uniq
    end
  end
end
