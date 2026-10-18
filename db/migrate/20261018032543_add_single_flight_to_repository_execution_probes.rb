class AddSingleFlightToRepositoryExecutionProbes < ActiveRecord::Migration[8.1]
  INDEX_NAME = "idx_repository_execution_probes_single_flight"

  def up
    add_column :repository_execution_probes, :in_flight, :boolean unless column_exists?(:repository_execution_probes, :in_flight)
    execute <<~SQL.squish
      UPDATE repository_execution_probes
      SET in_flight = CASE WHEN status IN ('queued', 'running') THEN TRUE ELSE NULL END
    SQL
    change_column_default :repository_execution_probes, :in_flight, from: nil, to: true
    add_index :repository_execution_probes, %i[repository_id in_flight], unique: true,
      name: INDEX_NAME, if_not_exists: true
  end

  def down
    remove_index :repository_execution_probes, name: INDEX_NAME, if_exists: true
    remove_column :repository_execution_probes, :in_flight if column_exists?(:repository_execution_probes, :in_flight)
  end
end
