module App
  class DependencyGatePayload
    def self.for(dependency)
      new(dependency).payload
    end

    def initialize(dependency)
      @dependency = dependency
    end

    def payload
      {
        satisfaction_mode: dependency.satisfaction_mode,
        required_deployment_stage_name: required_deployment_stage_name,
        latest_deployment_stage: latest_deployment_stage
      }
    end

    private

    attr_reader :dependency

    def required_deployment_stage_name
      dependency.required_deployment_stage_name if dependency.respond_to?(:required_deployment_stage_name)
    end

    def latest_deployment_stage
      return nil unless dependency.depends_on_job

      plan = RepoDeploymentStagesReader.for_repository(dependency.depends_on_job.repository)
      return nil if plan.stages.empty?

      App::DeploymentStageSummary.for(dependency.depends_on_job, stages: plan.stages)
    end
  end
end
