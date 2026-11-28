# frozen_string_literal: true

require "rails_helper"
require "erb"
require "yaml"

# SolidQueue's fan-out jobs (PollAllMainBranchHealthJob, PollAllDeploymentStagesJob,
# PollAllMergeStatesJob, PollAllPullRequestsJob, ...) bulk-enqueue many child jobs at once.
# Under MySQL's default REPEATABLE READ isolation, concurrent INSERTs into the same table
# take gap locks on adjacent index ranges, and overlapping fan-outs deadlock on
# solid_queue_jobs. READ COMMITTED drops those gap locks. Solid Cable polling does
# concurrent writes into a shared table too, so it gets the same treatment.
RSpec.describe "database transaction isolation" do
  def production_config
    raw = File.read(Rails.root.join("config/database.yml"))
    # config/database.yml serves SQLite when SYRUS_SQLITE is set; force the
    # MySQL branch so this spec reads the deploy-target configuration.
    previous = ENV["SYRUS_SQLITE"]
    ENV.delete("SYRUS_SQLITE")
    YAML.safe_load(ERB.new(raw).result, aliases: true).fetch("production")
  ensure
    ENV["SYRUS_SQLITE"] = previous
  end

  it "pins the queue and cable connections to READ COMMITTED" do
    %w[queue cable].each do |name|
      cfg = production_config.fetch(name)

      expect(cfg["adapter"]).to eq("mysql2")
      expect(cfg.dig("variables", "transaction_isolation")).to eq("READ-COMMITTED"),
        "#{name} does not pin transaction_isolation to READ-COMMITTED, so concurrent " \
        "fan-out inserts can deadlock on MySQL's default REPEATABLE READ gap locks"
    end
  end

  # NY45: the primary (and cache, which inherits it) runs at READ COMMITTED
  # too. Under REPEATABLE READ every plain read in a transaction answers from
  # the snapshot its first read fixed, which Lineage.lock! takes before it
  # waits on the row locks, so a check made after a lock could miss a
  # transaction that committed meanwhile (F149).
  it "pins the primary and cache connections to READ COMMITTED" do
    %w[primary cache].each do |name|
      cfg = production_config.fetch(name)

      expect(cfg["adapter"]).to eq("mysql2")
      expect(cfg.dig("variables", "transaction_isolation")).to eq("READ-COMMITTED"),
        "#{name} does not pin transaction_isolation to READ-COMMITTED"
    end
  end

  it "keeps the lock-wait ceiling and UTC time zone alongside the new isolation level" do
    %w[primary cache queue cable].each do |name|
      cfg = production_config.fetch(name)

      expect(cfg.dig("variables", "innodb_lock_wait_timeout")).to eq(10),
        "#{name} lost the innodb_lock_wait_timeout ceiling"
      expect(cfg.dig("variables", "time_zone")).to eq("+00:00"),
        "#{name} lost the UTC time zone pin"
    end
  end
end
