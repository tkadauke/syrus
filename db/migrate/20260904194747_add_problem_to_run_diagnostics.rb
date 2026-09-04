class AddProblemToRunDiagnostics < ActiveRecord::Migration[8.1]
  # The Problem a step declared when it failed, recorded beside the raw
  # exception. Nullable on purpose: most failures are still classified
  # downstream from evidence, and only a step that was certain fills this in.
  #
  # `problem_evidence` is nullable JSON with no DB default -- MySQL 8 refuses
  # a default on a JSON column, and nil is a fine reading of "no evidence".
  def up
    add_column :run_diagnostics, :problem_code, :string unless column_exists?(:run_diagnostics, :problem_code)
    add_column :run_diagnostics, :problem_evidence, :json unless column_exists?(:run_diagnostics, :problem_evidence)
    add_index :run_diagnostics, :problem_code unless index_exists?(:run_diagnostics, :problem_code)
  end

  def down
    remove_index :run_diagnostics, :problem_code if index_exists?(:run_diagnostics, :problem_code)
    remove_column :run_diagnostics, :problem_evidence if column_exists?(:run_diagnostics, :problem_evidence)
    remove_column :run_diagnostics, :problem_code if column_exists?(:run_diagnostics, :problem_code)
  end
end
