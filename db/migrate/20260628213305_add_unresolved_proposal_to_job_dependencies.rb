class AddUnresolvedProposalToJobDependencies < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:job_dependencies, :unresolved_chat_proposal_id)
      add_reference :job_dependencies,
                    :unresolved_chat_proposal,
                    null: true,
                    foreign_key: { to_table: :chat_proposals }
    end

    unless index_exists?(:job_dependencies, [ :job_id, :unresolved_chat_proposal_id ], name: "index_job_deps_on_unresolved_proposal_per_job")
      add_index :job_dependencies,
                [ :job_id, :unresolved_chat_proposal_id ],
                unique: true,
                where: "depends_on_job_id IS NULL AND unresolved_chat_proposal_id IS NOT NULL",
                name: "index_job_deps_on_unresolved_proposal_per_job"
    end
  end

  def down
    remove_index :job_dependencies, name: "index_job_deps_on_unresolved_proposal_per_job" if index_exists?(:job_dependencies, name: "index_job_deps_on_unresolved_proposal_per_job")
    remove_reference :job_dependencies, :unresolved_chat_proposal, foreign_key: { to_table: :chat_proposals } if column_exists?(:job_dependencies, :unresolved_chat_proposal_id)
  end
end
