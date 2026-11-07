# frozen_string_literal: true

require_relative "deploy_helper"

RSpec.describe Deploy::Config do
  def build(env = {}, **options)
    described_class.new(env: env, **options)
  end

  # The whole point of validating here: a bad duration must be rejected while
  # the cluster is still untouched, not discovered after Flux is suspended and
  # half the pods have been replaced.
  it "rejects a malformed duration before anything reads a cluster" do
    expect { build({ "ROLLOUT_TIMEOUT" => "15n" }) }
      .to raise_error(Deploy::UsageError, /ROLLOUT_TIMEOUT/)
  end

  it "rejects a non-integer flux suspend TTL" do
    expect { build({ "FLUX_SUSPEND_TTL" => "10m" }) }
      .to raise_error(Deploy::UsageError, /integer number of seconds/)
  end

  it "defaults to both clusters with their own kubeconfigs" do
    config = build
    expect(config.clusters.map(&:label)).to eq(%w[staging production])
    expect(config.clusters.map(&:namespace)).to eq(%w[syrus-staging syrus-production])
    expect(config.clusters.map(&:kubeconfig).uniq.length).to eq(2)
  end

  it "deploys one cluster when asked for one" do
    expect(build({}, production: false).clusters.map(&:label)).to eq([ "staging" ])
    expect(build({}, staging: false).clusters.map(&:label)).to eq([ "production" ])
  end

  # A dry run must never need an image: "build nothing" is a far easier
  # property to be sure of than classifying every docker subcommand.
  it "implies --skip-build for a dry run" do
    expect(build({}, dry_run: true).skip_build).to be(true)
  end

  describe "migration budgets" do
    # The correction this rewrite exists for. Scheduling and image pull are
    # short; applying migrations is legitimately long. One shared clock failed
    # a deploy -- and rolled production back -- over a data migration that was
    # running correctly.
    it "budgets startup and the migration run separately" do
      config = build
      expect(config.migration_start_timeout).to eq(300)
      expect(config.migration_run_timeout).to eq(1800)
    end

    # Raising DB_PREPARE_TIMEOUT is exactly how the incident was worked around
    # by hand, so the name keeps working and means what the operator meant.
    it "honours DB_PREPARE_TIMEOUT as the migration run budget" do
      expect(build({ "DB_PREPARE_TIMEOUT" => "45m" }).migration_run_timeout).to eq(2700)
    end

    it "prefers the explicit run timeout over the legacy alias" do
      config = build({ "MIGRATION_RUN_TIMEOUT" => "20m" })
      expect(config.migration_run_timeout).to eq(1200)
    end

    # Kubernetes must not kill the Job before this script decides to, or the
    # activeDeadlineSeconds becomes the real timeout and the phase's budget is
    # decoration.
    it "gives the Job a deadline that covers both budgets" do
      config = build
      expect(config.migration_deadline_seconds)
        .to be > config.migration_start_timeout + config.migration_run_timeout
    end
  end

  describe "the flux suspend budget" do
    # Every bounded phase that runs while Flux is down, plus one rollout
    # timeout for the unbounded setup and verification work.
    it "sums every bounded phase plus headroom" do
      config = build({
        "PREPULL_TIMEOUT" => "12m", "MIGRATION_START_TIMEOUT" => "5m",
        "MIGRATION_RUN_TIMEOUT" => "30m", "ROLLOUT_TIMEOUT" => "15m",
        "FLUX_SUSPEND_SLACK" => "5m"
      })

      expect(config.flux_suspend_budget_seconds(4))
        .to eq((12 + 5 + 30 + 5 * 15 + 5) * 60)
    end

    it "drops the pre-pull budget when pre-pull is off" do
      with_timeout = build({ "PREPULL" => "0", "PREPULL_TIMEOUT" => "12m" })
      without = build({ "PREPULL" => "0" })
      expect(with_timeout.flux_suspend_budget_seconds(1))
        .to eq(without.flux_suspend_budget_seconds(1))
    end

    # More rollout targets means a longer deploy, so plugin and optional
    # workloads have to extend the watchdog rather than quietly eat its margin.
    it "grows with the number of rollout targets" do
      config = build
      expect(config.flux_suspend_budget_seconds(6))
        .to be > config.flux_suspend_budget_seconds(4)
    end
  end
end
