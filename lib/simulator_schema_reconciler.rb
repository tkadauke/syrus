# frozen_string_literal: true

# bin/simulator reuses one SQLite database across invocations (see
# SimulatorTestDatabaseIdentity) so that a grader run does not replay
# db/schema.rb's 150+ tables for every scenario. The cost of that reuse is
# that the file outlives the schema which built it, and
# `ActiveRecord::Migration.maintain_test_schema!` does not close the gap: it
# compares migration *files* against schema_migrations rows, so a database
# whose rows claim a migration its tables never received looks healthy by that
# measure.
#
# The simulator then runs every scenario against the stale schema, and the
# missing column surfaces as a NoMethodError attributed to whatever work-engine
# service happened to read it -- a required landing grader failing with a
# message that points at the work engine instead of at its own database.
#
# Rails already records what each database was built from, in
# ar_internal_metadata.schema_sha1, so compare that against db/schema.rb and
# reload when they disagree. That is the same cheap checksum the persistent
# database was introduced to rely on, and it leaves the fast path untouched:
# an up-to-date database loads nothing.
module SimulatorSchemaReconciler
  module_function

  def call!(log: ->(message) { warn(message) })
    stale = stale_configs
    return false if stale.empty?

    stale.each do |config|
      log.call("[simulator] #{config.name} database #{config.database} was built from a different db/#{config.schema_dump} -- reloading the schema")
      ActiveRecord::Tasks::DatabaseTasks.load_schema(config, :ruby)
    end

    # A schema load retires the connection it ran through, so hand the next
    # caller a clean one rather than a pool pointing at the old file handle.
    ActiveRecord::Base.establish_connection(:primary)
    ActiveRecord::Base.clear_cache!
    # Boot runs before this, and any initializer that touched a model left it
    # holding attribute methods built from the schema we just replaced. Those
    # outlive the schema cache, which is what made the stale column surface as
    # a NoMethodError from a validator rather than as a missing column.
    ActiveRecord::Base.descendants.each(&:reset_column_information)
    true
  end

  def stale_configs
    ActiveRecord::Base.configurations.configs_for(env_name: Rails.env.to_s).reject do |config|
      next true if config.schema_dump.blank?
      next true unless Rails.root.join("db", config.schema_dump.to_s).exist?

      ActiveRecord::Tasks::DatabaseTasks.schema_up_to_date?(config, :ruby)
    end
  end
end
