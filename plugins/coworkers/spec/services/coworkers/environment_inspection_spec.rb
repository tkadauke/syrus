require "rails_helper"

RSpec.describe Coworkers::EnvironmentInspection do
  let(:owner) { Factories.user }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Inspector", handle: "environment-inspector",
                                workspace_repo: "https://github.com/acme/widgets.git")
  end
  let(:environment) { Coworkers::Environment.create!(coworker:, state: "candidate") }
  let(:namespace) do
    RuntimeImageNamespace.create!(name: "inspection", owner_kind: "coworker_environment",
                                  owner_ref: coworker.id.to_s, provider_key: "test")
  end

  def image(digest, retention_state: "default")
    RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{digest * 64}",
                         platform: "linux/amd64", source_kind: "coworker_environment", source_ref: digest,
                         availability: "available", retention_state:, published_at: Time.current)
  end

  it "serializes source, build, candidate, active, rollback, and compatibility state without restricted evidence" do
    active_image = image("a")
    rollback_image = image("b", retention_state: "retained")
    candidate_image = image("c")
    active = Coworkers::EnvironmentRevision.create!(environment:, number: 1, state: "active",
                                                     source_digest: "sha256:#{'1' * 64}", runtime_image: active_image,
                                                     runtime_abi: 3, compat_min: 2, compat_max: 4)
    Coworkers::EnvironmentRevision.create!(environment:, number: 2, state: "retired",
                                            source_digest: "sha256:#{'2' * 64}", runtime_image: rollback_image,
                                            runtime_abi: 3, compat_min: 2, compat_max: 4)
    request = RuntimeImageBuildRequest.create!(runtime_image_namespace: namespace, state: "succeeded",
                                               platform: "linux/amd64", dedup_key: "inspection-dedup",
                                               source_kind: "coworker_environment", source_ref: "candidate",
                                               source_digest: "sha256:#{'3' * 64}", recipe_digest: "sha256:#{'4' * 64}",
                                               requester_kind: "coworker", requester_ref: coworker.id.to_s)
    RuntimeImageBuildResult.create!(request:, runtime_image: candidate_image, outcome: "succeeded",
                                    finished_at: Time.current,
                                    details: { "evidence" => { "outcome" => "succeeded", "layer_count" => 2,
                                                               "sanitized_log" => "restricted",
                                                               "destinations" => [ "private.example" ] } })
    candidate = Coworkers::EnvironmentRevision.create!(environment:, number: 3, state: "candidate",
                                                        source_digest: "sha256:#{'5' * 64}", runtime_image: candidate_image,
                                                        build_request: request, runtime_abi: 3, compat_min: 2, compat_max: 4)
    environment.update!(active_revision: active, active_runtime_image: active_image,
                        candidate_revision: candidate, candidate_runtime_image: candidate_image)
    base = RuntimeImages::BuildRequests::Base.new(id: 9, digest: "sha256:#{'6' * 64}", runtime_abi: 3,
                                                   compat_min: 2, compat_max: 4)
    allow(Syrus::Host::RuntimeImages).to receive(:active_base).and_return(base)

    snapshot = described_class.new(environment).call
    candidate_request = snapshot.candidate_revision.build_request

    expect(snapshot.candidate_revision.association(:runtime_image)).to be_loaded
    expect(snapshot.candidate_revision.association(:build_request)).to be_loaded
    expect(candidate_request.association(:result)).to be_loaded
    expect(candidate_request.association(:evidences)).to be_loaded
    expect(snapshot.active_revision.association(:runtime_image)).to be_loaded

    payload = Coworkers::EnvironmentInspectionSerializer.new(snapshot).as_json

    expect(payload).to include("v" => 1, "active_digest" => active_image.digest)
    expect(payload.dig("current_source_revision", "number")).to eq(3)
    expect(payload.dig("build_status", "state")).to eq("succeeded")
    expect(payload.fetch("candidate_verification_summary")).to eq("outcome" => "succeeded", "layer_count" => 2)
    expect(payload.fetch("retained_rollback_digests")).to contain_exactly(
      "digest" => rollback_image.digest, "revision_id" => kind_of(Integer), "revision_number" => 2
    )
    expect(payload.fetch("compatibility")).to include("status" => "compatible", "current_runtime_abi" => 3)
    expect(payload.to_json).not_to include("restricted", "private.example", "sanitized_log", "destinations")
  end

  it "uses the safe summary when restricted build evidence is available" do
    candidate_image = image("c")
    request = RuntimeImageBuildRequest.create!(runtime_image_namespace: namespace, state: "succeeded",
                                               platform: "linux/amd64", dedup_key: "evidence-dedup",
                                               source_kind: "coworker_environment", source_ref: "candidate",
                                               source_digest: "sha256:#{'3' * 64}", recipe_digest: "sha256:#{'4' * 64}",
                                               requester_kind: "coworker", requester_ref: coworker.id.to_s)
    attempt = request.attempts.create!(number: 1, state: "succeeded", started_at: 1.minute.ago,
                                       finished_at: Time.current)
    RuntimeImageBuildEvidence.create!(request:, attempt:, runtime_image: candidate_image, outcome: "succeeded",
                                      source_digest: request.source_digest, image_digest: candidate_image.digest,
                                      destinations: [ { "host" => "private.example", "address" => "10.0.0.1", "count" => 2 } ],
                                      policy_snapshot: [ { "rule" => "restricted-policy" } ],
                                      log: "restricted build output", log_bytes: 23, finished_at: Time.current)
    candidate = Coworkers::EnvironmentRevision.create!(environment:, number: 1, state: "candidate",
                                                        source_digest: request.source_digest, runtime_image: candidate_image,
                                                        build_request: request)
    environment.update!(candidate_revision: candidate, candidate_runtime_image: candidate_image)
    allow(Syrus::Host::RuntimeImages).to receive(:active_base).and_return(nil)

    snapshot = described_class.new(environment).call
    candidate_request = snapshot.candidate_revision.build_request

    expect(candidate_request.association(:evidences)).to be_loaded
    expect(candidate_request.evidences.last.association(:attempt)).to be_loaded

    payload = Coworkers::EnvironmentInspectionSerializer.new(snapshot).as_json

    expect(payload.fetch("candidate_verification_summary")).to include(
      "attempt" => 1, "outcome" => "succeeded", "destination_count" => 2, "log_bytes" => 23
    )
    expect(payload.to_json).not_to include("private.example", "10.0.0.1", "restricted-policy", "restricted build output")
  end
end
