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

    investigation = AlertmanagerInvestigations::Investigation.sole
    expect(investigation.job).to eq(job)
    expect(investigation.fingerprint).to eq("abc123")
    expect(investigation.host).to eq("worker-1")
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
