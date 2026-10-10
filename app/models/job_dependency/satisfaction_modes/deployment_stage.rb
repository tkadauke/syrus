class JobDependency
  module SatisfactionModes
    class DeploymentStage < Base
      def dependency_succeeded?
        return false unless dependency.depends_on_job_id.present?
        return false if dependency.required_deployment_stage_name.blank?

        dependency.depends_on_job.deployment_stage_statuses.exists?(stage_name: dependency.required_deployment_stage_name)
      end

      def terminal_unsuccessful_for_execution?
        return false if dependency_succeeded?
        return false unless dependency.depends_on_job&.closed?

        !dependency.depends_on_job.dependency_succeeded?
      end

      def validate!
        validate_target!
        validate_stage_name!
      end

      private

      def validate_target!
        return if dependency.depends_on_job_id.present?

        dependency.errors.add(:depends_on_job, "must be a Job for deployment-stage dependencies")
      end

      def validate_stage_name!
        stage_name = dependency.required_deployment_stage_name.to_s
        if stage_name.blank?
          dependency.errors.add(:required_deployment_stage_name, "can't be blank for deployment-stage dependencies")
          return
        end
        return unless dependency.depends_on_job

        plan = RepoDeploymentStagesReader.for_repository(dependency.depends_on_job.repository)
        unless plan.enabled?
          dependency.errors.add(:required_deployment_stage_name, "requires deployment_stages to be configured for the upstream repository")
          return
        end

        return if plan.stages.any? { |stage| stage.name == stage_name }

        dependency.errors.add(:required_deployment_stage_name, "is not configured for the upstream repository")
      end
    end
  end
end
