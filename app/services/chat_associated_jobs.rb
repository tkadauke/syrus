class ChatAssociatedJobs
  PROPOSAL_KINDS = %w[job syrus_issue].freeze

  def self.scope(chat_session)
    proposal_ids = ChatProposal.confirmed
      .where(chat_session_id: chat_session.id)
      .where(kind: PROPOSAL_KINDS)
      .where.not(job_id: nil)
      .select(:job_id)

    Job.where(id: proposal_ids).or(Job.where(linked_chat_id: chat_session.id, kind: "direct"))
  end
end
