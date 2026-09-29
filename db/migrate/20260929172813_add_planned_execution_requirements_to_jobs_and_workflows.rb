class AddPlannedExecutionRequirementsToJobsAndWorkflows < ActiveRecord::Migration[8.1]
  def change
    add_planned_execution_columns(:jobs)
    add_planned_execution_columns(:workflows)
  end

  private

  def add_planned_execution_columns(table)
    add_column table, :planned_execution_project_label, :string unless column_exists?(table, :planned_execution_project_label)
    add_column table, :planned_execution_target_label, :string unless column_exists?(table, :planned_execution_target_label)
    add_column table, :planned_execution_capabilities, :json unless column_exists?(table, :planned_execution_capabilities)
    add_column table, :planned_execution_source, :string unless column_exists?(table, :planned_execution_source)
  end
end
