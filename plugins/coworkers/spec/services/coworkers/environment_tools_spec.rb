require "rails_helper"

RSpec.describe Coworkers::EnvironmentTools do
  let(:owner) { Factories.user }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Toolsmith", handle: "environment-toolsmith",
                                workspace_repo: "https://github.com/acme/widgets.git")
  end
  let!(:environment) { Coworkers::Environment.create!(coworker:, state: "draft") }
  let(:tool_context) { instance_double(Syrus::Host::ToolContext, user: owner, agent_actor: coworker, role: AgentRole::COWORKER_CHAT) }

  before do
    Feature.create!(slug: "coworker_custom_environments", category: "Labs", name: "x", enabled: true, experimental: true)
    allow(AppSetting).to receive(:beta_mode_enabled?).and_return(true)
    allow(Syrus::Host::ToolContext).to receive(:from_server_context).and_return(tool_context)
    allow(Syrus::Host::RuntimeImages).to receive(:active_base).and_return(nil)
    allow(Syrus::Events).to receive(:publish)
  end

  it "returns the safe inspection contract" do
    response = Coworkers::EnvironmentTools::Inspect.call(server_context: {})
    payload = JSON.parse(response.content.first[:text])

    expect(payload.fetch("environment")).to include("v" => 1, "environment_id" => environment.id,
                                                     "state" => "draft", "error_code" => nil)
  end

  it "returns an actionable structured error when the live gate is disabled" do
    Feature.find_by!(slug: "coworker_custom_environments").update!(enabled: false)

    response = Coworkers::EnvironmentTools::Inspect.call(server_context: {})
    payload = JSON.parse(response.content.first[:text])

    expect(response).to be_error
    expect(payload.fetch("error")).to include(
      "code" => "feature_disabled", "retryable" => false,
      "next_action" => "Ask an administrator to enable coworker custom environments."
    )
  end

  it "requests a build and emits its durable lifecycle event" do
    revision = double(id: 41, environment_id: environment.id, environment:)
    result = double(revision:, status: { revision_id: 41, build_state: "queued" })
    request = instance_double(Coworkers::EnvironmentBuildRequest, call: result)
    workspace = instance_double(Coworkers::Workspace)
    allow(Coworkers::Workspace).to receive(:for).with({}).and_return(workspace)
    allow(Coworkers::EnvironmentBuildRequest).to receive(:new).with(coworker, workspace).and_return(request)

    response = Coworkers::EnvironmentTools::RequestBuild.call(server_context: {}, reason: "Add ffmpeg")
    payload = JSON.parse(response.content.first[:text])

    expect(request).to have_received(:call).with(created_by: owner, reason: "Add ffmpeg")
    expect(payload.fetch("request")).to include("revision_id" => 41, "build_state" => "queued")
    expect(Syrus::Events).to have_received(:publish).with(
      "coworker_environment.build_requested",
      hash_including(coworker_id: coworker.id, environment_id: environment.id, revision_id: 41)
    )
  end

  it "publishes an authorized candidate" do
    revision = Coworkers::EnvironmentRevision.create!(environment:, number: 1, state: "candidate",
      source_digest: "sha256:#{'a' * 64}")
    environment.update!(state: "candidate", candidate_revision: revision)
    authority = double(allow?: true)
    lifecycle = instance_double(Coworkers::EnvironmentLifecycle, publish!: revision)
    allow(Coworkers::EnvironmentTools::RequestPublication).to receive(:publication_risk).and_return(double)
    allow(Coworkers::EnvironmentPublicationAuthority).to receive(:new)
      .and_return(instance_double(Coworkers::EnvironmentPublicationAuthority, call: authority))
    allow(Coworkers::EnvironmentLifecycle).to receive(:new).with(environment).and_return(lifecycle)

    response = Coworkers::EnvironmentTools::RequestPublication.call(server_context: {}, reason: "Ready")
    payload = JSON.parse(response.content.first[:text])

    expect(lifecycle).to have_received(:publish!).with(revision, actor: "coworker:#{coworker.id}", authority:)
    expect(payload.fetch("published")).to be(true)
  end

  it "returns an actionable approval error when publication needs confirmation" do
    revision = Coworkers::EnvironmentRevision.create!(environment:, number: 1, state: "candidate",
      source_digest: "sha256:#{'a' * 64}")
    environment.update!(state: "candidate", candidate_revision: revision)
    authority = double(allow?: false, ask?: true)
    allow(Coworkers::EnvironmentTools::RequestPublication).to receive(:publication_risk).and_return(double)
    allow(Coworkers::EnvironmentPublicationAuthority).to receive(:new)
      .and_return(instance_double(Coworkers::EnvironmentPublicationAuthority, call: authority))

    response = Coworkers::EnvironmentTools::RequestPublication.call(server_context: {}, reason: "Ready")
    payload = JSON.parse(response.content.first[:text])

    expect(response).to be_error
    expect(payload.fetch("error")).to include(
      "code" => "approval_required", "next_action" => "Ask the owner to approve the publication request."
    )
    expect(Syrus::Events).to have_received(:publish).with(
      "coworker_environment.approval_required", hash_including(revision_id: revision.id)
    )
  end

  it "rolls back only to the revision advertised by inspection" do
    revision = Coworkers::EnvironmentRevision.create!(environment:, number: 1, state: "retired",
      source_digest: "sha256:#{'b' * 64}")
    snapshot = instance_double(Coworkers::EnvironmentInspection::Snapshot, rollback_revisions: [ revision ])
    inspection = instance_double(Coworkers::EnvironmentInspection, call: snapshot)
    success_inspection = Coworkers::EnvironmentInspection.new(environment)
    activation = double(id: 73)
    lifecycle = instance_double(Coworkers::EnvironmentLifecycle, rollback!: activation)
    allow(Coworkers::EnvironmentInspection).to receive(:new).with(environment)
      .and_return(inspection, success_inspection)
    allow(Coworkers::EnvironmentLifecycle).to receive(:new).with(environment).and_return(lifecycle)

    response = Coworkers::EnvironmentTools::RequestRollback.call(
      server_context: {}, revision_id: revision.id, reason: "Current image will not launch"
    )
    payload = JSON.parse(response.content.first[:text])

    expect(lifecycle).to have_received(:rollback!)
      .with(actor: "coworker:#{coworker.id}", target_revision: revision)
    expect(payload).to include("rolled_back" => true, "activation_id" => 73)
  end

  it "rejects a rollback without a reason before changing the environment" do
    allow(Coworkers::EnvironmentLifecycle).to receive(:new)

    response = Coworkers::EnvironmentTools::RequestRollback.call(
      server_context: {}, revision_id: 12, reason: " "
    )
    payload = JSON.parse(response.content.first[:text])

    expect(response).to be_error
    expect(payload.dig("error", "message")).to eq("reason is required")
    expect(Coworkers::EnvironmentLifecycle).not_to have_received(:new)
  end
end
