class AddRepositoryStateScopeIndexToWorkIntents < ActiveRecord::Migration[8.1]
  def change
    add_index :work_intents,
      [ :repository_id, :scope_type, :state, :scope_id ],
      name: "idx_work_intents_repo_scope_state_scope_id",
      if_not_exists: true
  end
end
