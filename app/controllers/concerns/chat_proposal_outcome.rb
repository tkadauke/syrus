# Proposal-outcome helpers extracted from Api::V1::App::ChatsController.
#
# After a chat proposal is confirmed or rejected, these build the operator-
# facing notice and the agent-facing confirmation/rejection text, and
# best-effort start a just-created Epic. They are pure controller helpers
# (reading `params`/`Current.user`, delegating to the proposal's materialized
# result), so they mix straight back in with no behavior change. Kept private
# on include.
module ChatProposalOutcome
  private

  def maybe_start_confirmed_epic!(proposal, result)
    return false unless ActiveModel::Type::Boolean.new.cast(params[:start])
    return false unless proposal.epic_bundle?

    epic = result.respond_to?(:epic) ? result.epic : nil
    return false unless epic
    return true if epic.in_progress?

    epic.start_implementing_or_request!(actor: Current.user) == :started
  rescue Epic::NotStartable
    false
  rescue StandardError => e
    Rails.logger.error(
      "[ChatsController] best-effort Epic start after confirming proposal ##{proposal.id} failed — " \
      "confirmation proceeds unstarted: #{e.class}: #{e.message}"
    )
    false
  end

  def proposal_confirmed_notice(proposal, result, epic_started: false)
    record = result.respond_to?(:epic) && result.epic ? result.epic : result.jobs.first || proposal.reload.materialized_record
    notice = case record
    when Job
      "Proposal confirmed and filed as #{record.slug}."
    when Epic
      "Proposal confirmed and filed as #{record.slug}."
    else
      "Proposal confirmed."
    end

    epic_started ? "#{notice} #{I18n.t('api.epics.started')}" : notice
  end

  def proposal_confirmation_text(proposal, result, epic_started: false)
    if result.respond_to?(:epic) && result.epic
      child_jobs = Array(result.jobs).map { |job| proposal_job_label(job) }.join(", ")
      text = %(Proposal confirmed. Epic ##{result.epic.id} "#{result.epic.title}" was created.)
      text += " Child jobs: #{child_jobs}." if child_jobs.present?
      text += " The Epic was started; ready child Jobs are dispatching." if epic_started
      return text
    end

    job = Array(result.respond_to?(:jobs) ? result.jobs : []).first || proposal.job
    return "Proposal confirmed. #{proposal_job_label(job)} was created." if job

    issue_number = result.github_issue_numbers[proposal.id] if result.respond_to?(:github_issue_numbers)
    issue_number ||= proposal.github_issue_number
    if issue_number
      return %(Proposal confirmed. GitHub issue ##{issue_number} "#{proposal.title}" was filed.)
    end

    %(Proposal confirmed. "#{proposal.title}" was filed.)
  end

  def proposal_rejection_text(proposal)
    %(Proposal rejected. "#{proposal.title}" was discarded.)
  end

  def proposal_job_label(job)
    %(#{job.slug} "#{job.issue_title}")
  end
end
