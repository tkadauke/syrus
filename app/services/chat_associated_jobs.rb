class ChatAssociatedJobs
  PROPOSAL_KINDS = %w[job syrus_issue].freeze

  def self.scope(chat_session)
    scope_for(ChatSession.where(id: chat_session.id))
  end

  def self.scope_for(chat_sessions)
    chat_ids = chat_sessions.select(:id)
    proposal_ids = ChatProposal.confirmed
      .where(chat_session_id: chat_ids)
      .where(kind: PROPOSAL_KINDS)
      .where.not(job_id: nil)
      .select(:job_id)

    Job.where(id: proposal_ids).or(Job.where(linked_chat_id: chat_ids, kind: "direct"))
  end
end
