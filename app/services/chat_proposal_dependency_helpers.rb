module ChatProposalDependencyHelpers
  private

  def create_pending_proposal_dependency!(job, dependency, requirement: nil)
    return unless dependency.syrus_issue? || dependency.job?
    if requirement&.fetch("satisfaction_mode", nil) == "deployment_stage"
      raise ArgumentError, "deployment-stage dependencies require a materialized upstream Job; #{dependency.slug} is still only a proposal"
    end

    JobDependency.find_or_create_by!(
      job: job,
      unresolved_chat_proposal: dependency
    ) do |job_dependency|
      job_dependency.source = "manual"
      job_dependency.created_by_user = user
      apply_dependency_requirement!(job_dependency, requirement)
    end
  end

  def resolve_pending_proposal_dependencies_for(proposal, job)
    JobDependency.pending.where(unresolved_chat_proposal: proposal).find_each do |dependency|
      next unless dependency.job.user_id == user.id

      validate_dependency_target!(
        job,
        satisfaction_mode: dependency.satisfaction_mode,
        required_deployment_stage_name: dependency.required_deployment_stage_name,
        dependent_job: dependency.job
      )
      dependency.resolve!(depends_on_job: job)
      Rails.logger.info(
        "[JobDependency] resolved pending proposal dep on #{::App::Presentation.job_slug(dependency.job_id)}: " \
        "#{proposal.slug} -> #{job.slug}"
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn(
        "[JobDependency] failed to resolve pending proposal dep on #{::App::Presentation.job_slug(dependency.job_id)}: #{e.message}"
      )
    end
  end

  def validate_dependency_target!(target, satisfaction_mode: "success", required_deployment_stage_name: nil, dependent_job: nil)
    ProposalDependencyValidator.validate!(
      target,
      satisfaction_mode: satisfaction_mode,
      required_deployment_stage_name: required_deployment_stage_name,
      dependent_job: dependent_job
    )
  end

  def apply_dependency_requirement!(job_dependency, requirement)
    requirement ||= {}
    job_dependency.satisfaction_mode = requirement.fetch("satisfaction_mode", "success")
    job_dependency.required_deployment_stage_name = requirement["required_deployment_stage_name"]
  end
end
