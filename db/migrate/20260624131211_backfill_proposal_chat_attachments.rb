class BackfillProposalChatAttachments < ActiveRecord::Migration[8.1]
  def up
    ChatProposal.where(state: [ "confirmed", "filed" ]).where.not(job_id: nil).find_each do |proposal|
      ChatAttachment.find_or_create_by!(
        chat_session_id: proposal.chat_session_id,
        attachable_type: "Job",
        attachable_id: proposal.job_id
      )
    end

    ChatProposal.where(state: [ "confirmed", "filed" ]).where.not(epic_id: nil).find_each do |proposal|
      ChatAttachment.find_or_create_by!(
        chat_session_id: proposal.chat_session_id,
        attachable_type: "Epic",
        attachable_id: proposal.epic_id
      )
    end
  end

  def down
  end
end
