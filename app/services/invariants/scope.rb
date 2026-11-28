module Invariants
  # Which slice of the world an evaluation looks at. Production evaluates
  # everything; the simulator restricts evaluation to the scenario's own Jobs
  # so rows left behind by other examples cannot produce violations.
  Scope = Data.define(:job_ids) do
    def self.all = new(job_ids: nil)

    def self.for_jobs(ids) = new(job_ids: Array(ids).map(&:to_i).uniq.sort)

    def all? = job_ids.nil?

    # Restrict `relation` to rows whose `column` names an in-scope Job.
    def restrict(relation, column = :id)
      all? ? relation : relation.where(column => job_ids)
    end

    def include_job?(job_id)
      all? || job_ids.include?(job_id.to_i)
    end

    def as_json(*)
      all? ? { all: true } : { all: false, job_ids: job_ids }
    end
  end
end
