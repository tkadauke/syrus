require "rails_helper"
require_relative "../support/snapshot_factory"
require Rails.root.join("plugins/syrus_coverage/db/migrate/20261123120000_rename_coverage_snapshots_for_syrus_coverage")

RSpec.describe RenameCoverageSnapshotsForSyrusCoverage do
  let(:connection) { ActiveRecord::Base.connection }

  def run_migration(direction)
    ActiveRecord::Migration.suppress_messages { described_class.new.public_send(direction) }
  end

  it "keeps recorded snapshots when the table moves to the plugin prefix and back" do
    snapshot = SyrusCoverageFactories.snapshot(lines_pct: 81.5, data: { "app/a.rb" => { "lines_pct" => 50.0 } })

    run_migration(:down)
    expect(connection.table_exists?(:coverage_snapshots)).to be(true)
    expect(connection.table_exists?(:syrus_coverage_snapshots)).to be(false)
    legacy = connection.select_one("SELECT id, sha, lines_pct, data FROM coverage_snapshots WHERE id = #{snapshot.id}")
    expect(legacy["sha"]).to eq(snapshot.sha)

    run_migration(:up)
    SyrusCoverage::Snapshot.reset_column_information

    expect(connection.table_exists?(:coverage_snapshots)).to be(false)
    restored = SyrusCoverage::Snapshot.find(snapshot.id)
    expect(restored.sha).to eq(snapshot.sha)
    expect(restored.lines_pct.to_f).to eq(81.5)
    expect(restored.data).to eq({ "app/a.rb" => { "lines_pct" => 50.0 } })
    expect(connection.index_exists?(:syrus_coverage_snapshots, [ :repository_id, :project_id, :branch, :created_at ], name: "idx_coverage_snapshots_project_branch")).to be(true)
  end

  it "is idempotent when the table has already been renamed" do
    expect { run_migration(:up) }.not_to raise_error
    expect(connection.table_exists?(:syrus_coverage_snapshots)).to be(true)
  end

  it "does nothing on an installation that never had coverage snapshots" do
    run_migration(:down)
    connection.drop_table(:coverage_snapshots)

    expect { run_migration(:up) }.not_to raise_error
  end
end
