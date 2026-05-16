class AddApprovalStateToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :approved_at, :datetime
    add_column :jobs, :approved_via, :string
    add_reference :jobs, :approved_by_user, null: true, foreign_key: { to_table: :users }
    add_column :jobs, :approval_evidence, :json, default: {}, null: false
  end
end
