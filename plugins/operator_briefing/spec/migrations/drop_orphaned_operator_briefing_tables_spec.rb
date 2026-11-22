require "rails_helper"
require_relative "../../db/migrate/20261121172512_drop_orphaned_operator_briefing_tables"

# Databases that ran the original detector migration still hold these two
# tables; fresh installs never had them. The drop must clear the first and be
# a no-op on the second, and on a second run.
RSpec.describe DropOrphanedOperatorBriefingTables do
  subject(:migration) { described_class.new }

  let(:connection) { ActiveRecord::Base.connection }
  let(:tables) { %w[operator_briefing_review_findings operator_briefing_workflow_notable_changes] }

  around do |example|
    ActiveRecord::Migration.suppress_messages { example.run }
  end

  it "drops both leftover tables and stays idempotent" do
    tables.each { |table| connection.create_table(table) { |t| t.integer :workflow_id } }

    migration.migrate(:up)
    expect(tables.map { |table| connection.table_exists?(table) }).to eq([ false, false ])

    expect { migration.migrate(:up) }.not_to raise_error
  end

  it "leaves the plugin's live tables alone" do
    live = connection.tables.select { |table| table.start_with?("operator_briefing") } - tables
    expect(live).not_to be_empty

    migration.migrate(:up)

    expect(connection.tables.select { |table| table.start_with?("operator_briefing") } - tables).to match_array(live)
  end
end
