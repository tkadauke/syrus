class AddApprovalWithdrawnAtToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :approval_withdrawn_at, :datetime
  end
end
