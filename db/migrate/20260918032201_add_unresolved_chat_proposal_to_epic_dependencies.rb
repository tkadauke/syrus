class AddUnresolvedChatProposalToEpicDependencies < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:epic_dependencies, :unresolved_chat_proposal_id)
      add_column :epic_dependencies, :unresolved_chat_proposal_id, :bigint
    end

    unless index_exists?(:epic_dependencies, :unresolved_chat_proposal_id)
      add_index :epic_dependencies, :unresolved_chat_proposal_id
    end

    unless index_exists?(:epic_dependencies, [ :epic_id, :unresolved_chat_proposal_id ], name: "index_epic_deps_on_epic_and_unresolved_proposal")
      add_index :epic_dependencies, [ :epic_id, :unresolved_chat_proposal_id ],
                unique: true,
                where: "depends_on_epic_id IS NULL AND depends_on_job_id IS NULL AND unresolved_chat_proposal_id IS NOT NULL",
                name: "index_epic_deps_on_epic_and_unresolved_proposal"
    end
  end
end
