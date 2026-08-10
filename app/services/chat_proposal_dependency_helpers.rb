module ChatProposalDependencyHelpers
  private

  def create_pending_proposal_dependency!(job, dependency)
    return unless dependency.syrus_issue? || dependency.job?

    JobDependency.find_or_create_by!(
      job: job,
      unresolved_chat_proposal: dependency
    ) do |job_dependency|
      job_dependency.source = "manual"
      job_dependency.created_by_user = user
    end
  end

  def resolve_pending_proposal_dependencies_for(proposal, job)
    JobDependency.pending.where(unresolved_chat_proposal: proposal).find_each do |dependency|
      next unless dependency.job.user_id == user.id

      validate_dependency_target!(job)
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

  def validate_dependency_target!(target)
    ProposalDependencyValidator.validate!(target)
  end
end
