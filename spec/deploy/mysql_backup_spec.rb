# frozen_string_literal: true

require_relative "deploy_helper"
require "stringio"

RSpec.describe Deploy::MysqlBackup do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:reporter) { Deploy::Reporter.new(out: out, err: err) }
  let(:controls) { Deploy::ControlStack.new(reporter: reporter) }
  let(:clock) { Deploy::Clock::Fake.new }

  def build(resources, env: {}, running: [])
    fake = DeploySpec::FakeKubectl.new(namespace: "syrus-production", resources: resources)
    fake.define_singleton_method(:jsonpath) do |*target, path|
      next running.shift.to_s if path.include?("status.phase")

      super(*target, path)
    end
    context = DeploySpec.context(
      kubectl: fake, config: Deploy::Config.new(env: env), clock: clock,
      reporter: reporter, controls: controls, label: "production"
    )
    [ described_class.new(context), fake ]
  end

  let(:cronjob) { { "kind" => "CronJob", "spec" => { "suspend" => false } } }

  it "proceeds when the cluster has no backup cronjob" do
    backup, fake = build({})

    backup.suspend!

    expect(fake.writes).to be_empty
    expect(out.string).to include("not found — proceeding")
  end

  it "suspends, registers the resume, and resumes" do
    backup, fake = build({ "cronjob syrus-mysql-backup" => cronjob }, running: [ "" ])

    backup.suspend!
    expect(controls.pending).to include("cronjob/syrus-mysql-backup suspension")

    backup.resume!

    expect(fake.writes.map { |write| write[:patch] })
      .to eq([ { "spec" => { "suspend" => true } }, { "spec" => { "suspend" => false } } ])
    expect(controls).to be_empty
  end

  # Resuming what this deploy did not suspend would undo an operator decision
  # the script knows nothing about.
  it "leaves an operator's own suspension alone" do
    backup, fake = build({ "cronjob syrus-mysql-backup" => { "spec" => { "suspend" => true } } })

    backup.suspend!
    backup.resume!

    expect(fake.writes).to be_empty
  end

  # A half-written backup is worth less than no backup, so a running one gets a
  # grace period before it is cut off.
  it "waits for a running backup before the rollout" do
    backup, fake = build(
      { "cronjob syrus-mysql-backup" => cronjob },
      running: [ *Array.new(4) { "syrus-mysql-backup-123\n" }, "" ]
    )

    backup.suspend!

    expect(out.string).to include("waiting for mysql backup syrus-mysql-backup-123")
    expect(fake.actions).not_to include("delete job syrus-mysql-backup-123")
  end

  it "deletes a backup that is still running when the grace period is up" do
    backup, fake = build(
      { "cronjob syrus-mysql-backup" => cronjob },
      env: { "MYSQL_BACKUP_DRAIN_SECONDS" => "10s" },
      running: Array.new(20) { "syrus-mysql-backup-123\n" }
    )

    backup.suspend!

    expect(err.string).to include("still running after 10s; deleting it before rollout")
    expect(fake.actions).to include("delete job syrus-mysql-backup-123")
  end
end
