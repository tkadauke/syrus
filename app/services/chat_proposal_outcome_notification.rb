class ChatProposalOutcomeNotification
  SOURCE = "proposal_notification".freeze

  def self.confirmed_message(proposal)
    new(proposal).confirmed_message
  end

  def self.rejected_message(proposal)
    new(proposal).rejected_message
  end

  def initialize(proposal)
    @proposal = proposal
  end

  def confirmed_message
    if proposal.job
      return "Proposal \"#{proposal.title}\" was confirmed as JOB-#{proposal.job.id} " \
        "(proposal slug: #{proposal.slug})."
    end

    if proposal.epic
      child_job_labels = proposal.child_proposals.confirmed.includes(:job).filter_map do |child|
        "JOB-#{child.job.id}" if child.job
      end

      if child_job_labels.any?
        return "Proposal \"#{proposal.title}\" was confirmed as EPIC-#{proposal.epic.id} " \
          "with child jobs #{child_job_labels.join(", ")} (proposal slug: #{proposal.slug})."
      end
    end

    %(Proposal "#{proposal.title}" was confirmed (proposal slug: #{proposal.slug}).)
  end

  def rejected_message
    %(Proposal "#{proposal.title}" was rejected (proposal slug: #{proposal.slug}).)
  end

  private

  attr_reader :proposal
end
