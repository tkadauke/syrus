require "rails_helper"

# The harness that keeps a migration spec from poisoning the rest of its
# process. See spec/support/migration_schema_cache.rb for why that happens:
# the per-example transaction rolls a migration's DDL back, Rails' column
# cache does not follow, and a migration that raises before its own cleanup
# leaves the cache describing a column the table no longer has.
RSpec.describe Syrus::SpecSupport::MigrationSchemaCache do
  # Belt and braces: this file is not under spec/migrations, so the
  # append_after hook does not cover it, and leaving a stale cache here would
  # reproduce the very bug it tests against every later example.
  after { described_class.reset! }

  it "drops a cached column the table no longer has" do
    ActiveRecord::Base.connection.add_column(:users, :zz_cache_probe, :string)
    User.reset_column_information
    expect(User.column_names).to include("zz_cache_probe")

    ActiveRecord::Base.connection.remove_column(:users, :zz_cache_probe)
    # The state a failed migration spec leaves behind: gone from the table,
    # still in the cache, so the next insert names a column that isn't there.
    expect(User.column_names).to include("zz_cache_probe")

    described_class.reset!

    expect(User.column_names).not_to include("zz_cache_probe")
    expect { Factories.user }.not_to raise_error
  end

  it "keeps going when one model cannot read its columns" do
    Class.new(ActiveRecord::Base) do
      def self.name = "ZzMissingTableModel"
      self.table_name = "zz_table_that_does_not_exist"
    end

    expect { described_class.reset! }.not_to raise_error
  end
end
