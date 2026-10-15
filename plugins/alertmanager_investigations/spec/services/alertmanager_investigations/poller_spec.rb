require "rails_helper"

RSpec.describe AlertmanagerInvestigations::Poller do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "infra", default_branch: "main") }
  let(:configuration) do
    instance_double(AlertmanagerInvestigations::Configuration, host_label: "instance", rate_limit_window: 30.minutes)
  end
  let(:client) { instance_double(AlertmanagerInvestigations::Client, firing_alerts: alerts) }
  let(:runbook_url) { "https://github.com/acme/infra/blob/main/runbooks/disk.md" }
  let(:alert_payload) do
    {
      "fingerprint" => "abc123",
      "labels" => { "alertname" => "DiskMissing", "instance" => "worker-1" },
      "annotations" => { "runbook_url" => runbook_url },
      "startsAt" => "2026-10-08T10:00:00Z"
    }
  end
  let(:alerts) { [ alert_payload ] }

  before do
    PluginRecord.find_or_create_by!(name: "alertmanager_investigations").update!(enabled: true)
    stub_repository_content(repository, files: { "runbooks/disk.md" => "Check the node and collect disk state." })
  end

  it "creates no Job for an alert with no resolvable runbook" do
    alerts.first["annotations"] = {}

    expect { described_class.new(client: client, configuration: configuration).call }.not_to change(Job, :count)
  end

  it "creates no Job for a suppressed alert even when Alertmanager returns it" do
    alerts.first["status"] = { "state" => "suppressed" }

    expect {
      described_class.new(client: client, configuration: configuration).call
    }.not_to change(Job, :count)
  end

  it "creates exactly one investigation Job with the alert payload and runbook in the prompt" do
    expect {
      described_class.new(client: client, configuration: configuration).call
    }.to change(Job.where(investigation: true), :count).by(1)
      .and change(AlertmanagerInvestigations::Investigation, :count).by(1)

    job = Job.where(investigation: true).sole
    expect(job).to be_direct
    expect(job.issue_body).to include("DiskMissing")
    expect(job.issue_body).to include('"fingerprint": "abc123"')
    expect(job.issue_body).to include("Check the node and collect disk state.")
    expect(job.issue_body).to include("escalation_reason")
    expect(job.issue_body).to include("unsafe_to_proceed")

    investigation = AlertmanagerInvestigations::Investigation.sole
    expect(investigation.job).to eq(job)
    expect(investigation.fingerprint).to eq("abc123")
    expect(investigation.host).to eq("worker-1")
  end

  it "records an alert failure by fingerprint and continues processing later alerts" do
    alerts << alert_payload.deep_dup.tap do |payload|
      payload["fingerprint"] = "def456"
      payload["labels"]["instance"] = "worker-2"
    end
    calls = 0
    allow(InvestigationJobs::Creator).to receive(:call).and_wrap_original do |original, **kwargs|
      calls += 1
      next InvestigationJobs::Creator::Result.new(job: nil, error: "broken runbook") if calls == 1

      original.call(**kwargs)
    end

    expect(Rails.logger).to receive(:warn)
      .with("[AlertmanagerInvestigations] alert abc123 failed: RuntimeError: broken runbook")

    expect {
      described_class.new(client: client, configuration: configuration).call
    }.to change(Job.where(investigation: true), :count).by(1)
      .and change(AlertmanagerInvestigations::Investigation, :count).by(1)

    expect(AlertmanagerInvestigations::Investigation.sole.fingerprint).to eq("def456")
  end

  it "propagates client failures for the poll callback to handle" do
    allow(client).to receive(:firing_alerts).and_raise(AlertmanagerInvestigations::Client::Error, "unavailable")

    expect {
      described_class.new(client: client, configuration: configuration).call
    }.to raise_error(AlertmanagerInvestigations::Client::Error, "unavailable")
  end

  it "creates nothing for a second firing inside the rate-limit window" do
    described_class.new(client: client, configuration: configuration).call

    expect {
      described_class.new(client: client, configuration: configuration).call
    }.not_to change(Job, :count)
  end

  it "creates nothing while the same host already has an open investigation" do
    existing_job = Factories.job_record(
      repository: repository,
      user: user,
      kind: "direct",
      issue_number: nil,
      investigation: true,
      state: "running"
    )
    AlertmanagerInvestigations::Investigation.create!(
      fingerprint: "other-fingerprint",
      host: "worker-1",
      runbook_url: runbook_url,
      repository: repository,
      job: existing_job
    )

    expect {
      described_class.new(client: client, configuration: configuration).call
    }.not_to change(Job, :count)
  end
end
