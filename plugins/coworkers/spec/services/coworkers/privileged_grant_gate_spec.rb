require "rails_helper"

RSpec.describe Coworkers::PrivilegedGrantGate do
  let(:descriptor) do
    Coworkers::GrantCatalog::Descriptor.new(
      name: "database.read", label: "Database", description: "Read a database", maximum_policy: "confirm",
      tools: [ "read_database" ], scope_options_callback: nil, scope_label_callback: nil, valid_scope_callback: nil,
      privileged: true
    )
  end

  it "requires both a live confinement-capable worker and the broker" do
    allow(described_class).to receive(:confined_worker_available?).and_return(false)
    allow(described_class).to receive(:confinement_unavailability_reason).and_return("confinement_probe_failed")
    expect(described_class.availability(descriptor).reason).to eq("confinement_probe_failed")

    allow(described_class).to receive(:confined_worker_available?).and_return(true)
    allow(described_class).to receive(:broker_authorization_available?).and_return(false)
    expect(described_class.availability(descriptor).reason).to eq("broker_authorization_unavailable")

    allow(described_class).to receive(:broker_authorization_available?).and_return(true)
    expect(described_class.availability(descriptor)).to be_available
  end

  it "distinguishes missing worker configuration, missing probes, and failed verification" do
    worker = InstanceVersion.create!(hostname: "worker", role: "worker", version: "test", started_at: Time.current,
      last_heartbeat_at: Time.current, capabilities: { "os" => [ "linux" ] }, capability_diagnostics: {})

    expect(described_class.send(:confinement_unavailability_reason)).to eq("confinement_probe_missing")

    worker.update!(capability_diagnostics: {
      "confined_coworker" => false,
      "confined_coworker_configuration" => "missing",
      "confined_coworker_missing_settings" => [ "docker_transport" ]
    })
    expect(described_class.send(:confinement_unavailability_reason)).to eq("confinement_configuration_missing")

    worker.update!(capability_diagnostics: {
      "confined_coworker" => false,
      "confined_coworker_configuration" => "complete",
      "confined_coworker_probe_status" => "failed"
    })
    expect(described_class.send(:confinement_unavailability_reason)).to eq("confinement_probe_failed")
  end

  it "discovers broker authorization through the plugin registry" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "credential_store" }
    allow(Syrus::PluginRegistry).to receive(:all_plugins).and_return([ manifest.with(enabled: false) ])

    expect(described_class.send(:broker_authorization_available?)).to be(false)

    allow(Syrus::PluginRegistry).to receive(:all_plugins).and_return([ manifest.with(enabled: true) ])
    allow(Syrus::PluginRegistry).to receive(:health).and_return(instance_double(Syrus::PluginHealth, healthy?: true))

    expect(described_class.send(:broker_authorization_available?)).to be(true)
  end

  it "suppresses a previously assigned privileged grant after capability loss" do
    owner = Factories.user
    repository = Factories.repository(user: owner)
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-gated", workspace_repo: repository.remote_url)
    allow(Coworkers::GrantCatalog).to receive(:fetch).with("database.read").and_return(descriptor)
    allow(described_class).to receive(:availability).with(descriptor).and_return(
      described_class::Availability.new(available?: false, reason: "confinement_unavailable")
    )
    coworker.grants.create!(capability: "database.read", approval_policy: "confirm")

    expect(described_class.allowed_capabilities(coworker)).to be_empty
  end

  it "requires confinement only while a privileged grant is held" do
    owner = Factories.user
    repository = Factories.repository(user: owner)
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-routing", workspace_repo: repository.remote_url)
    allow(Coworkers::GrantCatalog).to receive(:all).and_return([ descriptor ])

    expect(described_class.confinement_required?(coworker)).to be(false)

    grant = coworker.grants.create!(capability: "database.read", approval_policy: "confirm")
    expect(described_class.confinement_required?(coworker)).to be(true)

    grant.destroy!
    expect(described_class.confinement_required?(coworker)).to be(false)
  end

  it "fails over a privileged turn to a live confined worker and blocks when none remains" do
    owner = Factories.user
    repository = Factories.repository(user: owner)
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-failover", workspace_repo: repository.remote_url)
    allow(Coworkers::GrantCatalog).to receive(:fetch).with("database.read").and_return(descriptor)
    allow(Coworkers::GrantCatalog).to receive(:all).and_return([ descriptor ])
    coworker.grants.create!(capability: "database.read", approval_policy: "confirm")
    allow(WorkerCapabilities).to receive(:current).and_return(capabilities: { "runtime" => [] })
    worker = InstanceVersion.create!(hostname: "confined-worker", role: "worker", version: "test", started_at: Time.current,
      last_heartbeat_at: Time.current, capabilities: { "os" => [ "linux" ], "runtime" => [ "confined_coworker" ] })

    expect(described_class.turn_admission(coworker)).to eq(queue: ::Workflow.resume_queue_name(worker.hostname))

    worker.update!(finished_at: Time.current)
    expect(described_class.turn_admission(coworker)).to eq(outcome: "confinement_unavailable")
  end
end
