class ChatAssociatedJobs
  PROPOSAL_KINDS = %w[job syrus_issue].freeze

  # For one chat, resolve the ids with two indexed lookups. The relation
  # form below ORs two IN-subqueries, which MySQL can only answer by scanning
  # every Job row: ~10k rows and ~105 ms per call in production, on every
  # chat job-status read.
  def self.scope(chat_session)
    proposal_job_ids = ChatProposal.confirmed
      .where(chat_session_id: chat_session.id, kind: PROPOSAL_KINDS)
      .where.not(job_id: nil)
      .pluck(:job_id)
    direct_job_ids = Job.where(linked_chat_id: chat_session.id, kind: "direct").pluck(:id)

    Job.where(id: (proposal_job_ids + direct_job_ids).uniq)
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
