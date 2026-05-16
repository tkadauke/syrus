class AddProposalLifecycleFields < ActiveRecord::Migration[8.1]
  def up
    add_reference :chat_proposals, :epic, foreign_key: true unless column_exists?(:chat_proposals, :epic_id)
    add_column :chat_proposals, :confirmed_at, :datetime unless column_exists?(:chat_proposals, :confirmed_at)
    add_column :chat_proposals, :rejected_at, :datetime unless column_exists?(:chat_proposals, :rejected_at)
    add_column :chat_proposals, :withdrawn_at, :datetime unless column_exists?(:chat_proposals, :withdrawn_at)
    add_column :chat_proposals, :edited_at, :datetime unless column_exists?(:chat_proposals, :edited_at)
    change_column_default :chat_proposals, :state, from: "pending", to: "proposed"

    execute <<~SQL.squish
      UPDATE chat_proposals
      SET state = CASE state
        WHEN 'pending' THEN 'proposed'
        WHEN 'filed' THEN 'confirmed'
        WHEN 'discarded' THEN 'withdrawn'
        ELSE state
      END
    SQL

    execute <<~SQL.squish
      UPDATE chat_proposals
      SET confirmed_at = filed_at
      WHERE state = 'confirmed' AND confirmed_at IS NULL AND filed_at IS NOT NULL
    SQL

    execute <<~SQL.squish
      UPDATE chat_proposals
      SET withdrawn_at = discarded_at
      WHERE state = 'withdrawn' AND withdrawn_at IS NULL AND discarded_at IS NOT NULL
    SQL
  end

  def down
    execute <<~SQL.squish
      UPDATE chat_proposals
      SET state = CASE state
        WHEN 'proposed' THEN 'pending'
        WHEN 'confirmed' THEN 'filed'
        WHEN 'rejected' THEN 'discarded'
        WHEN 'withdrawn' THEN 'discarded'
        ELSE state
      END
    SQL

    remove_reference :chat_proposals, :epic, foreign_key: true if column_exists?(:chat_proposals, :epic_id)
    change_column_default :chat_proposals, :state, from: "proposed", to: "pending"
    remove_column :chat_proposals, :confirmed_at if column_exists?(:chat_proposals, :confirmed_at)
    remove_column :chat_proposals, :rejected_at if column_exists?(:chat_proposals, :rejected_at)
    remove_column :chat_proposals, :withdrawn_at if column_exists?(:chat_proposals, :withdrawn_at)
    remove_column :chat_proposals, :edited_at if column_exists?(:chat_proposals, :edited_at)
  end
end
