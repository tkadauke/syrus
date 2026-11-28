# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("lib/simulator_schema_reconciler")

RSpec.describe SimulatorSchemaReconciler do
  # Regression: reloading a stale simulator database loaded the new schema
  # over the old file and failed with "index ... already exists", so
  # bin/simulator could not start until the file was deleted by hand.
  it "purges a stale database before loading the current schema into it" do
    config = instance_double(ActiveRecord::DatabaseConfigurations::HashConfig,
                             name: "primary", database: "storage/test_simulator.sqlite3", schema_dump: "schema.rb")
    allow(described_class).to receive(:stale_configs).and_return([ config ])
    calls = []
    allow(ActiveRecord::Tasks::DatabaseTasks).to receive(:purge) { calls << :purge }
    allow(ActiveRecord::Tasks::DatabaseTasks).to receive(:load_schema) { calls << :load_schema }
    allow(ActiveRecord::Base).to receive(:establish_connection)
    allow(ActiveRecord::Base).to receive(:clear_cache!)

    expect(described_class.call!(log: ->(_message) {})).to be(true)
    expect(calls).to eq(%i[purge load_schema])
  end

  it "loads nothing when every database matches its schema" do
    allow(described_class).to receive(:stale_configs).and_return([])
    expect(ActiveRecord::Tasks::DatabaseTasks).not_to receive(:load_schema)

    expect(described_class.call!(log: ->(_message) {})).to be(false)
  end
end
