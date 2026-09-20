# frozen_string_literal: true

# bin/simulator used to pick a brand-new random TEST_ENV_NUMBER (and delete
# the resulting SQLite files at exit) on every single invocation, so every
# grader run paid the full cost of replaying db/schema.rb's 150+ tables into
# an empty file via `ActiveRecord::Migration.maintain_test_schema!` -- the
# dominant cost behind the work-engine-simulations grader running 5-6x
# longer than every sibling grader in the same fanout batch.
#
# A stable suffix instead lets the primary and search SQLite files persist
# across invocations within the same workspace, so `maintain_test_schema!`
# can just compare a schema checksum and skip instead of rebuilding from
# scratch -- the same trick bin/rspec-fast's `parallel:prepare` already
# relies on for its numbered test<N>.sqlite3 databases.
#
# The suffix stays non-numeric on purpose: parallel_tests (see
# bin/rspec-worker) only ever sets TEST_ENV_NUMBER to "" or a bare digit, so
# this can never collide with a concurrently running rspec worker's database
# file.
#
# This is a flat top-level module (not nested under WorkEngine::Simulation)
# deliberately: bin/simulator requires it before config/environment boots
# Zeitwerk, and reopening an app/-namespaced module that early (e.g. via a
# plain `module WorkEngine; module Simulation; ...; end; end`) would
# pre-create that constant and permanently short-circuit Zeitwerk's autoload
# for app/services/work_engine/simulation.rb, silently losing whatever that
# file defines (see lib/syrus_sidecar_bootstrap.rb for the same pattern).
module SimulatorTestDatabaseIdentity
  STABLE_ENV_NUMBER = "_simulator"

  module_function

  def ensure_env_number!(env: ENV)
    return unless env["TEST_ENV_NUMBER"].to_s.empty?

    env["TEST_ENV_NUMBER"] = STABLE_ENV_NUMBER
  end
end
