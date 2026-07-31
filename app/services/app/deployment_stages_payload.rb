module App
  class DeploymentStagesPayload
    def self.for_job(job, plan: nil)
      new(job: job, plan: plan).payload
    end

    def initialize(job:, plan: nil)
      @job = job
      @plan = plan || RepoDeploymentStagesReader.for_repository(job.repository)
    end

    def payload
      return nil if stages.empty?

      statuses = @job.deployment_stage_statuses.index_by(&:stage_name)
      stages.map do |stage|
        status = statuses[stage.name]
        {
          name: stage.name,
          label: stage.label,
          reached: status.present?,
          reached_at: status&.reached_at&.iso8601,
          tag_sha: status&.tag_sha
        }
      end
    end

    private

    def stages
      @plan.stages
    end
  end
end
