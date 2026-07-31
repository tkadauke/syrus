module App
  class DeploymentStageSummary
    def self.for(job, stages:)
      new(job: job, stages: stages).for_job
    end

    def initialize(job:, stages:)
      @job = job
      @stages = Array(stages)
    end

    def for_job
      return nil if stages.empty?

      statuses_by_name = job.deployment_stage_statuses.index_by(&:stage_name)
      stage = stages.reverse.find { |candidate| statuses_by_name.key?(candidate.name) }
      return nil unless stage

      status = statuses_by_name.fetch(stage.name)
      {
        name: stage.name,
        label: stage.label,
        reached_at: status.reached_at&.iso8601
      }
    end

    private

    attr_reader :job, :stages
  end
end
