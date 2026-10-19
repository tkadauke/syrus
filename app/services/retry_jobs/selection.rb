module RetryJobs
  class Selection
    Result = Data.define(:jobs, :error) do
      def success? = error.blank?
    end

    def self.call(jobs) = new(jobs).call

    def initialize(jobs)
      @jobs = jobs.index_by(&:id)
    end

    def call
      ordered = []
      visiting = {}
      visited = {}
      jobs.each_key { |id| visit(id, visiting, visited, ordered) }
      Result.new(jobs: ordered, error: nil)
    rescue Cycle
      Result.new(jobs: [], error: "The selected Jobs contain a dependency cycle.")
    end

    private

    Cycle = Class.new(StandardError)
    attr_reader :jobs

    def visit(id, visiting, visited, ordered)
      return if visited[id]
      raise Cycle if visiting[id]

      visiting[id] = true
      JobDependency.resolved.where(job_id: id, depends_on_job_id: jobs.keys).pluck(:depends_on_job_id).sort.each do |upstream_id|
        visit(upstream_id, visiting, visited, ordered)
      end
      visiting.delete(id)
      visited[id] = true
      ordered << jobs.fetch(id)
    end
  end
end
