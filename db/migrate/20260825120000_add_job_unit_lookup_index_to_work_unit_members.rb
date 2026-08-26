class AddJobUnitLookupIndexToWorkUnitMembers < ActiveRecord::Migration[8.1]
  def change
    unless index_exists?(:work_unit_members, [ :job_id, :work_unit_id ], name: "idx_work_unit_members_job_unit")
      add_index :work_unit_members, [ :job_id, :work_unit_id ], name: "idx_work_unit_members_job_unit"
    end
  end
end
