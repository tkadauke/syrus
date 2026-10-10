class AddRequiredDeploymentStageNameToJobDependencies < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:job_dependencies, :required_deployment_stage_name)
      add_column :job_dependencies, :required_deployment_stage_name, :string
    end

    unless index_exists?(:job_dependencies, [ :depends_on_job_id, :satisfaction_mode, :required_deployment_stage_name ], name: "idx_job_dependencies_on_deployment_stage_gate")
      add_index :job_dependencies,
                [ :depends_on_job_id, :satisfaction_mode, :required_deployment_stage_name ],
                name: "idx_job_dependencies_on_deployment_stage_gate"
    end
  end
end
