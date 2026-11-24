class RenameCoverageSnapshotsForSyrusCoverage < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:coverage_snapshots)
    return if table_exists?(:syrus_coverage_snapshots)

    rename_table :coverage_snapshots, :syrus_coverage_snapshots
  end

  def down
    return unless table_exists?(:syrus_coverage_snapshots)
    return if table_exists?(:coverage_snapshots)

    rename_table :syrus_coverage_snapshots, :coverage_snapshots
  end
end
