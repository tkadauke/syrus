# A migration spec mutates the real schema of the shared test database: it
# calls `up` and `down` for real. SQLite's DDL is transactional, so the
# per-example transaction rolls those changes back -- but Rails' column cache
# does not take part in that rollback, which is why these specs reset it by
# hand.
#
# Doing that only at the end of their own hooks is where it goes wrong. A
# migration that raises partway -- an old data migration meeting NOT NULL
# columns its table grew long afterwards, say -- aborts the hook before the
# reset, leaving the cache describing a column the rolled-back table no longer
# has. Every later example in the process that inserts that table then fails
# with "table X has no column named Y", and because the ci-only specs run in
# one serial pass, "later" means dozens of unrelated files. The failures land
# on whichever spec ran next, which is a long way from the spec that caused
# them: that is how a single dead migration's spec kept the main branch red
# for weeks while the blame sat on workflow_workspace_spec.
#
# So reset the cache for them, after the fixture transaction has rolled back
# (`append_after` runs after rspec-rails tears it down) and regardless of
# whether their own hooks got that far.
module Syrus
  module SpecSupport
    module MigrationSchemaCache
      module_function

      # Drops every model's cached column list so the next access re-reads it
      # from the database. Cheap relative to a migration spec, and only ever
      # runs after one.
      def reset!
        ActiveRecord::Base.descendants.each do |model|
          model.reset_column_information
        rescue StandardError
          # An abstract or half-defined model is not worth failing teardown over.
          next
        end
      end
    end
  end
end

RSpec.configure do |config|
  config.define_derived_metadata(file_path: %r{/spec/migrations/}) do |metadata|
    metadata[:resets_schema_cache] = true
  end

  config.append_after(resets_schema_cache: true) do
    Syrus::SpecSupport::MigrationSchemaCache.reset!
  end
end
