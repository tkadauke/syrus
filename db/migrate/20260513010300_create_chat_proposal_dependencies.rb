class CreateChatProposalDependencies < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_proposal_dependencies do |t|
      t.references :proposal, null: false, foreign_key: { to_table: :chat_proposals }
      t.references :depends_on, null: false, foreign_key: { to_table: :chat_proposals }

      t.timestamps
    end

    add_index :chat_proposal_dependencies,
              [ :proposal_id, :depends_on_id ],
              unique: true,
              name: "index_chat_prop_deps_on_proposal_and_depends_on"
  end
end
