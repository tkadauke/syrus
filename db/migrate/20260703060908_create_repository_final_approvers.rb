class CreateRepositoryFinalApprovers < ActiveRecord::Migration[8.1]
  def up
    create_table :repository_final_approvers, if_not_exists: true do |t|
      t.references :repository, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.timestamps
    end
    unless index_exists?(:repository_final_approvers, [ :repository_id, :user_id ])
      add_index :repository_final_approvers, [ :repository_id, :user_id ], unique: true,
        name: "index_repo_final_approvers_on_repository_and_user"
    end
  end

  def down
    drop_table :repository_final_approvers, if_exists: true
  end
end
