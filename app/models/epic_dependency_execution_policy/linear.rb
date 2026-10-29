require "set"

class EpicDependencyExecutionPolicy::Linear
  def initialize(epic)
    @epic = epic
  end

  def ready?
    return false unless Feature.early_epic_dependency_execution_enabled?

    unfinished = @epic.dependencies.includes(depends_on_epic: { jobs: :runs }).reject(&:dependency_succeeded?)
    return false if unfinished.empty? || unfinished.any? { |dependency| dependency.depends_on_epic.nil? }

    upstreams = unfinished.map(&:depends_on_epic).uniq
    return false unless upstreams.one?
    return false unless execution_ready?(upstreams.first)

    anchor!(upstreams.first)
  end

  private

  def execution_ready?(upstream)
    return false unless upstream.repository_id == @epic.repository_id
    return false unless upstream.resolved_epic_dependency_policy == "linear"
    return false unless @epic.resolved_epic_dependency_policy == "linear"

    jobs = upstream.work_jobs.to_a
    jobs.any? && linear_endpoints(jobs) && jobs.all? do |job|
      job.branch_name.present? &&
        (job.pr_number.present? || job.external_pr_number.present?) &&
        job.head_sha.present?
    end
  end

  def anchor!(upstream)
    upstream_tail = linear_endpoints(upstream.work_jobs.to_a)&.last
    downstream_root = linear_endpoints(@epic.work_jobs.to_a)&.first
    return false unless upstream_tail && downstream_root

    Job.transaction do
      downstream_root.update!(parent_job: upstream_tail) unless downstream_root.parent_job_id == upstream_tail.id
      JobDependency.find_or_create_by!(job: downstream_root, depends_on_job: upstream_tail) do |dependency|
        dependency.source = "manual"
      end
    end
    true
  rescue ActiveRecord::RecordInvalid
    false
  end

  def linear_endpoints(jobs)
    return nil if jobs.empty?

    ids = jobs.map(&:id).to_set
    edges = JobDependency.where(job_id: ids, depends_on_job_id: ids).pluck(:job_id, :depends_on_job_id)
    incoming = edges.group_by(&:first)
    outgoing = edges.group_by(&:last)
    roots = jobs.reject { |job| incoming.key?(job.id) }
    tails = jobs.reject { |job| outgoing.key?(job.id) }
    return nil unless roots.one? && tails.one? && edges.size == jobs.size - 1

    visited = Set.new
    current = roots.first
    while current
      return nil if visited.include?(current.id)

      visited << current.id
      next_id = outgoing.fetch(current.id, []).first&.first
      current = jobs.find { |job| job.id == next_id }
    end
    return nil unless visited.size == jobs.size

    [ roots.first, tails.first ]
  end
end
