require "rails_helper"

RSpec.describe Coworkers::EnvironmentBuildRequest do
  include ActiveJob::TestHelper

  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Builder", handle: "env-builder",
                                workspace_repo: repository.remote_url)
  end
  let(:root) { Pathname.new(Dir.mktmpdir) }
  let(:workspace) do
    chat = ChatSession.create!(user: owner)
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    allow(Syrus::Host::ChatWorkspaces).to receive(:repo_path_for).and_return(root)
    Coworkers::Workspace.new(chat)
  end
  let(:service) { described_class.new(coworker, workspace) }
  let(:base) do
    RuntimeImages::BuildRequests::Base.new(id: 71, digest: "sha256:" + ("b" * 64), runtime_abi: 3,
                                           compat_min: 2, compat_max: 4)
  end

  before do
    Feature.create!(slug: "coworker_custom_environments", category: "Labs", name: "x", enabled: true, experimental: true)
    allow(AppSetting).to receive(:beta_mode_enabled?).and_return(true)
    allow(Syrus::Host::RuntimeImages).to receive(:active_base).and_return(base)
  end

  after { FileUtils.remove_entry(root) }

  it "snapshots inputs, pins base and policy, and dispatches an isolated build request" do
    Coworkers::EnvironmentSource.new(coworker, workspace).seed!
    workspace.write("environment/environment.yml",
                    "schema_version: 1\nnetwork_classes: [rubygems]\nsmoke_test: ./smoke-test\nreason: tools\nresources:\n  memory_mb: 512\n")

    expect { @result = service.call(created_by: owner) }
      .to have_enqueued_job(RuntimeImageBuildDispatchJob)

    revision = @result.revision.reload
    request = @result.build_request.reload
    expect(revision).to have_attributes(state: "building", runtime_image_build_request_id: request.id,
                                        coworker_base_release_id: 71, runtime_abi: 3, compat_min: 2, compat_max: 4,
                                        recipe_digest: request.recipe_digest)
    expect(revision.environment.reload.state).to eq("building")
    expect(request.source_archive).to be_attached
    expect(request.recipe.dig("build_args", "SYRUS_COWORKER_BASE")).to eq(base.digest)
    expect(request.recipe.dig("input_policy", "base_digest")).to eq(base.digest)
    expect(request.recipe.dig("input_policy", "network_classes")).to eq([ "rubygems" ])
    expect(request.recipe.dig("input_policy", "smoke_test")).to eq("./smoke-test")
    expect(request.recipe.dig("input_policy", "build_network_policy_digest")).to match(/\Asha256:/)
    expect(request.recipe.dig("input_policy", "runtime_contract_digest")).to eq(RuntimeImages::RuntimeAbi.digest)
    expect(@result.status).to include(build_state: "queued", revision_state: "building", image_digest: nil)
  end

  it "deduplicates repeated requests for the captured revision" do
    Coworkers::EnvironmentSource.new(coworker, workspace).seed!
    first = service.call

    expect(Syrus::Host::RuntimeImages).not_to receive(:request_build)
    expect { @second = described_class.new(coworker.reload, workspace).call }.not_to change(RuntimeImageBuildRequest, :count)
    expect(@second.build_request).to eq(first.build_request)
  end

  it "requests a new candidate for unchanged source after a provider contract upgrade" do
    Coworkers::EnvironmentSource.new(coworker, workspace).seed!
    first = service.call
    environment = first.revision.environment
    replacement = environment.revisions.create!(
      number: environment.next_revision_number, state: "draft",
      source_digest: first.revision.source_digest, source_manifest: first.revision.source_manifest,
      created_by_user: owner
    )
    upgraded_digest = "sha256:#{'f' * 64}"
    allow(RuntimeImages::RuntimeAbi).to receive(:digest).and_return(upgraded_digest)

    rebuilt = described_class.new(coworker, nil).call_revision(replacement, base:)

    expect(rebuilt.build_request).not_to eq(first.build_request)
    expect(rebuilt.build_request.recipe.dig("input_policy", "runtime_contract_digest")).to eq(upgraded_digest)
    expect(RuntimeImageBuildRequest.where(id: [ first.build_request.id, rebuilt.build_request.id ]).count).to eq(2)
  end

  it "serializes concurrent admission onto one durable build request" do
    Coworkers::EnvironmentSource.new(coworker, workspace).seed!
    ready = Queue.new
    start = Queue.new
    services = 2.times.map { described_class.new(coworker.reload, workspace) }

    results = services.map do |concurrent_service|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          concurrent_service.call
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    results.map!(&:value)

    expect(results.map { |result| result.build_request.id }.uniq.one?).to be(true)
    expect(RuntimeImageBuildRequest.count).to eq(1)
  end

  it "rechecks the feature gate at the authoritative boundary" do
    Feature.find_by!(slug: "coworker_custom_environments").update!(enabled: false)

    expect { service.call }.to raise_error(described_class::Disabled)
    expect(RuntimeImageBuildRequest.count).to eq(0)
  end

  it "fails closed when no compatible base is active" do
    Coworkers::EnvironmentSource.new(coworker, workspace).seed!
    allow(Syrus::Host::RuntimeImages).to receive(:active_base).and_return(nil)

    expect { service.call }.to raise_error(described_class::BaseUnavailable)
    expect(RuntimeImageBuildRequest.count).to eq(0)
  end
end
