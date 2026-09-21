require "spec_helper"
require_relative "../../lib/simulator_test_database_identity"

RSpec.describe SimulatorTestDatabaseIdentity do
  describe ".ensure_env_number!" do
    it "assigns the stable suffix when TEST_ENV_NUMBER is unset" do
      env = {}

      described_class.ensure_env_number!(env: env)

      expect(env["TEST_ENV_NUMBER"]).to eq("_simulator")
    end

    it "assigns the stable suffix when TEST_ENV_NUMBER is blank" do
      env = { "TEST_ENV_NUMBER" => "" }

      described_class.ensure_env_number!(env: env)

      expect(env["TEST_ENV_NUMBER"]).to eq("_simulator")
    end

    it "does not override an explicitly set TEST_ENV_NUMBER" do
      env = { "TEST_ENV_NUMBER" => "_simulator_fresh_1234" }

      described_class.ensure_env_number!(env: env)

      expect(env["TEST_ENV_NUMBER"]).to eq("_simulator_fresh_1234")
    end

    it "does not override a parallel_tests-style numeric TEST_ENV_NUMBER" do
      env = { "TEST_ENV_NUMBER" => "3" }

      described_class.ensure_env_number!(env: env)

      expect(env["TEST_ENV_NUMBER"]).to eq("3")
    end

    it "is distinct from every value parallel_tests (bin/rspec-worker) can assign" do
      # bin/rspec-worker only ever sees "" (worker 1) or a bare digit
      # (worker 2+); the stable suffix must never collide with those so a
      # concurrently running rspec worker never shares this database file.
      expect(described_class::STABLE_ENV_NUMBER).not_to match(/\A\d*\z/)
    end
  end
end
