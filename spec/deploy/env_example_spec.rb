# frozen_string_literal: true

require_relative "deploy_helper"

# The knobs an operator reaches for when a deploy stalls have to be
# discoverable without reading the implementation.
RSpec.describe ".env.example deploy knobs" do
  subject(:env_example) { File.read(File.join(DeploySpec::ROOT, ".env.example")) }

  it "documents both migration budgets with their defaults" do
    expect(env_example).to include("MIGRATION_START_TIMEOUT=5m")
    expect(env_example).to include("MIGRATION_RUN_TIMEOUT=30m")
  end

  # Raising DB_PREPARE_TIMEOUT is how the single-budget incident was worked
  # around by hand, so an operator who remembers that name has to find it.
  it "says DB_PREPARE_TIMEOUT still works" do
    expect(env_example).to include("DB_PREPARE_TIMEOUT")
  end

  # A fixed TTL that is shorter than the deploy is how Flux resumes mid-rollout
  # and restores the previous image, so the default has to stay derived.
  it "leaves the flux watchdog TTL derived by default" do
    expect(env_example).to match(/^FLUX_SUSPEND_TTL=\s*#/)
    expect(env_example).not_to match(/^FLUX_SUSPEND_TTL=\d+/)
  end

  it "matches the defaults the implementation actually uses" do
    config = Deploy::Config.new(env: {})

    expect(env_example).to include("MIGRATION_START_TIMEOUT=#{Deploy::Duration.humanize(config.migration_start_timeout)}")
    expect(env_example).to include("MIGRATION_RUN_TIMEOUT=#{Deploy::Duration.humanize(config.migration_run_timeout)}")
    expect(env_example).to include("ROLLOUT_TIMEOUT=#{Deploy::Duration.humanize(config.rollout_timeout)}")
    expect(env_example).to include("FLUX_SUSPEND_SLACK=#{Deploy::Duration.humanize(config.flux_suspend_slack)}")
  end
end
