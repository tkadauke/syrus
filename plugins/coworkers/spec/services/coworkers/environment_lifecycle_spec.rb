require "rails_helper"

RSpec.describe Coworkers::EnvironmentLifecycle do
  let(:owner) { Factories.user }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Builder", handle: "lifecycle-builder",
                                workspace_repo: "https://github.com/acme/widgets.git")
  end
  let(:environment) { Coworkers::Environment.create!(coworker: coworker, state: "building") }
  let(:namespace) do
    RuntimeImageNamespace.create!(name: "coworker-lifecycle", owner_kind: "coworker_environment",
                                  owner_ref: coworker.id.to_s, provider_key: "test")
  end
  let(:image) do
    RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{'a' * 64}",
                         platform: "linux/amd64", source_kind: "coworker_environment", source_ref: "revision-1",
                         availability: "available", verification_state: "candidate", published_at: Time.current)
  end
  let(:request) do
    RuntimeImageBuildRequest.create!(runtime_image_namespace: namespace, state: "succeeded", platform: "linux/amd64",
                                     dedup_key: "dedup", source_kind: "coworker_environment", source_ref: "revision-1",
                                     source_digest: "sha256:#{'b' * 64}", recipe_digest: "sha256:#{'c' * 64}",
                                     requester_kind: "coworker", requester_ref: coworker.id.to_s)
  end
  let(:revision) do
    Coworkers::EnvironmentRevision.create!(environment: environment, number: 1, state: "verifying",
                                           source_digest: "sha256:#{'d' * 64}", runtime_abi: 3,
                                           compat_min: 2, compat_max: 4, build_request: request)
  end
  let(:base) { RuntimeImages::BuildRequests::Base.new(id: 1, digest: "sha256:#{'e' * 64}", runtime_abi: 3, compat_min: 2, compat_max: 4) }

  def accepted_attestation(runtime_image)
    policy = RuntimeImages::Builds::Runner.new.verification_policy(
      request, base_policy: RuntimeImages::Verifications::Policy.current
    )
    attempt = runtime_image.runtime_image_verification_attempts.create!(
      number: 1, image_digest: runtime_image.digest, state: "accepted", decision: "candidate",
      policy_snapshot: policy, policy_digest: RuntimeImages::Verifications::CanonicalJson.digest(policy),
      started_at: Time.current, finished_at: Time.current
    )
    attempt.create_attestation!(
      runtime_image:, image_digest: runtime_image.digest, policy_digest: attempt.policy_digest,
      evidence_digest: runtime_image.digest, outcome: "accepted", issued_at: Time.current, expires_at: 1.day.from_now
    )
  end

  def publication_authority(candidate)
    subject = Struct.new(:revision_id, :image_digest).new(candidate.id, candidate.runtime_image.digest)
    Struct.new(:subject, :lease, :inherited_from) { def allow? = true }.new(subject, nil, nil)
  end

  before do
    Feature.create!(slug: "coworker_custom_environments", category: "Labs", name: "x", enabled: true, experimental: true)
    allow(AppSetting).to receive(:beta_mode_enabled?).and_return(true)
    allow(Syrus::Host::RuntimeImages).to receive(:active_base).and_return(base)
    allow(Syrus::Host::RuntimeImages).to receive(:retain)
    allow(Syrus::Events).to receive(:publish)
    allow(Coworkers::EnvironmentPublicationAuthority).to receive(:revalidate!) do |authority, revision:, **|
      unless authority&.allow? && authority.subject.revision_id == revision.id &&
          authority.subject.image_digest == revision.runtime_image&.digest
        raise Coworkers::EnvironmentRevision::InvalidTransition, "publication authority does not match the candidate"
      end
      authority
    end
    RuntimeImageBuildResult.create!(request: request, runtime_image: image, outcome: "succeeded", finished_at: Time.current)
  end

  it "projects a verified successful build into a candidate" do
    described_class.new(environment).reconcile_build!(revision)

    expect(revision.reload).to have_attributes(state: "candidate", runtime_image_id: image.id)
    expect(environment.reload).to have_attributes(state: "candidate", candidate_revision_id: revision.id,
                                                   candidate_runtime_image_id: image.id, last_error_code: nil)
    expect(RuntimeImageAuditEvent.where(event_type: "coworker_environment.verified", runtime_image_id: image.id)).to exist
    expect(Syrus::Events).to have_received(:publish).with(
      "coworker_environment.candidate", hash_including(coworker_id: coworker.id, revision_id: revision.id,
                                                        inspection: hash_including("v" => 1, "state" => "candidate"))
    )
  end

  it "publishes atomically and retires the previous active revision" do
    previous = Coworkers::EnvironmentRevision.create!(environment: environment, number: 2, state: "active",
                                                       source_digest: "sha256:#{'f' * 64}", runtime_image: image)
    described_class.new(environment).reconcile_build!(revision)
    environment.update!(state: "candidate", active_revision: previous, active_runtime_image: image)
    attestation = accepted_attestation(image)

    described_class.new(environment).publish!(revision, actor: "operator", authority: publication_authority(revision))

    expect(previous.reload).to be_retired
    expect(revision.reload).to be_active
    expect(environment.reload).to have_attributes(state: "active", active_revision_id: revision.id,
                                                   candidate_revision_id: nil, active_activation_id: be_present)
    expect(environment.active_activation).to have_attributes(
      revision: revision, runtime_image: image, verification_attestation: attestation,
      source_digest: revision.source_digest, image_digest: image.digest, authority_kind: "permission"
    )
    expect(Coworkers::EnvironmentActiveSelection.resolve(environment)).to have_attributes(
      activation_id: environment.active_activation_id, revision_id: revision.id,
      runtime_image_id: image.id, image_digest: image.digest
    )
    expect(Syrus::Host::RuntimeImages).to have_received(:retain).with(image, reason: "active coworker environment", actor: "operator")
    expect(Syrus::Events).to have_received(:publish).with(
      "coworker_environment.activated", hash_including(revision_id: revision.id,
                                                        inspection: hash_including("active_digest" => image.digest))
    )
  end

  it "makes a replayed publication idempotent without creating another activation" do
    described_class.new(environment).reconcile_build!(revision)
    accepted_attestation(image)
    authority = publication_authority(revision)
    lifecycle = described_class.new(environment)
    lifecycle.publish!(revision, authority:)

    expect { lifecycle.publish!(revision.reload, authority:) }
      .not_to change { environment.activations.count }
    expect(environment.reload.active_revision_id).to eq(revision.id)
    expect(RuntimeImageAuditEvent.where(event_type: "coworker_environment.publication_replayed",
                                        runtime_image_id: image.id)).to exist
  end

  it "automatically rolls back after the configured repeated startup failures" do
    older_image = RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{'4' * 64}",
                                       platform: "linux/amd64", source_kind: "coworker_environment",
                                       source_ref: "older", availability: "available",
                                       verification_state: "candidate", published_at: 2.days.ago)
    prior_image = RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{'1' * 64}",
                                       platform: "linux/amd64", source_kind: "coworker_environment",
                                       source_ref: "prior", availability: "available",
                                       verification_state: "candidate", published_at: 1.day.ago)
    older_revision = Coworkers::EnvironmentRevision.create!(environment:, number: 1, state: "retired",
                                                             source_digest: "sha256:#{'5' * 64}", runtime_image: older_image,
                                                             runtime_abi: 3, compat_min: 2, compat_max: 4)
    prior_revision = Coworkers::EnvironmentRevision.create!(environment:, number: 2, state: "retired",
                                                             source_digest: "sha256:#{'2' * 64}", runtime_image: prior_image,
                                                             runtime_abi: 3, compat_min: 2, compat_max: 4)
    current_revision = Coworkers::EnvironmentRevision.create!(environment:, number: 3, state: "active",
                                                               source_digest: "sha256:#{'3' * 64}", runtime_image: image,
                                                               runtime_abi: 3, compat_min: 2, compat_max: 4)
    older_attestation = accepted_attestation(older_image)
    prior_attestation = accepted_attestation(prior_image)
    current_attestation = accepted_attestation(image)
    older = environment.activations.create!(revision: older_revision, runtime_image: older_image,
      verification_attestation: older_attestation, source_digest: older_revision.source_digest,
      image_digest: older_image.digest, authority_kind: "permission", actor: "operator", activated_at: 2.days.ago)
    prior = environment.activations.create!(revision: prior_revision, runtime_image: prior_image,
      previous_activation: older, verification_attestation: prior_attestation, source_digest: prior_revision.source_digest,
      image_digest: prior_image.digest, authority_kind: "permission", actor: "operator", activated_at: 1.day.ago)
    current = environment.activations.create!(revision: current_revision, runtime_image: image,
      previous_activation: prior, verification_attestation: current_attestation,
      source_digest: current_revision.source_digest, image_digest: image.digest,
      authority_kind: "permission", actor: "operator", activated_at: Time.current)
    environment.update!(state: "active", active_revision: current_revision,
                        active_runtime_image: image, active_activation: current)
    AppSetting.current.update!(coworker_environment_launch_failure_threshold: 2)

    recovery = Coworkers::EnvironmentRecovery.new(environment)
    recovery.record_launch_failure!(current.id, reason: "container_start_failed")
    expect(environment.reload.active_activation_id).to eq(current.id)
    recovery.record_launch_failure!(current.id, reason: "container_start_failed")

    first_rollback = environment.reload.active_activation
    expect(first_rollback).not_to eq(prior)
    expect(first_rollback).to have_attributes(previous_activation_id: older.id,
                                               environment_revision_id: prior_revision.id,
                                               runtime_image_id: prior_image.id)
    expect(environment).to have_attributes(active_revision_id: prior_revision.id,
                                                   active_runtime_image_id: prior_image.id)
    expect(current.reload.launch_failure_count).to eq(2)

    2.times { recovery.record_launch_failure!(first_rollback.id, reason: "container_start_failed") }
    expect(environment.reload).to have_attributes(active_revision_id: older_revision.id,
                                                   active_runtime_image_id: older_image.id)
    expect(environment.active_activation.previous_activation_id).to be_nil
    expect(RuntimeImageAuditEvent.where(event_type: "coworker_environment.rolled_back")).to exist
  end

  it "makes a replayed rollback idempotent after the active pointer advanced" do
    prior_image = RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{'1' * 64}",
      platform: "linux/amd64", source_kind: "coworker_environment", source_ref: "prior",
      availability: "available", verification_state: "candidate", published_at: 1.day.ago)
    prior_revision = Coworkers::EnvironmentRevision.create!(environment:, number: 2, state: "retired",
      source_digest: "sha256:#{'2' * 64}", runtime_image: prior_image, runtime_abi: 3, compat_min: 2, compat_max: 4)
    current_revision = Coworkers::EnvironmentRevision.create!(environment:, number: 3, state: "active",
      source_digest: "sha256:#{'3' * 64}", runtime_image: image, runtime_abi: 3, compat_min: 2, compat_max: 4)
    prior = environment.activations.create!(revision: prior_revision, runtime_image: prior_image,
      verification_attestation: accepted_attestation(prior_image), source_digest: prior_revision.source_digest,
      image_digest: prior_image.digest, authority_kind: "permission", actor: "operator", activated_at: 1.day.ago)
    current = environment.activations.create!(revision: current_revision, runtime_image: image,
      previous_activation: prior, verification_attestation: accepted_attestation(image),
      source_digest: current_revision.source_digest, image_digest: image.digest,
      authority_kind: "permission", actor: "operator", activated_at: Time.current)
    environment.update!(state: "active", active_revision: current_revision,
      active_runtime_image: image, active_activation: current)
    recovery = Coworkers::EnvironmentRecovery.new(environment)

    first = recovery.rollback!(failed_activation: current, actor: "operator")
    expect { recovery.rollback!(failed_activation: current, actor: "operator") }
      .not_to change { environment.activations.count }
    expect(environment.reload.active_activation_id).to eq(first.id)
    expect(RuntimeImageAuditEvent.where(event_type: "coworker_environment.rollback_replayed")).to exist
  end

  it "terminates active coworker turns for a severe revocation" do
    allow(Syrus::Host::AgentRuntime).to receive(:terminate_chat_processes).and_return(1)
    allow(Syrus::Host::RuntimeImages).to receive(:revoke) { |runtime_image, reason:, **| runtime_image.mark_revoked!(reason:) }
    revision.update!(runtime_image: image)

    described_class.new(environment).revoke!(revision, reason: "critical_vulnerability", severity: :severe)

    expect(Syrus::Host::AgentRuntime).to have_received(:terminate_chat_processes)
      .with(chat_session_ids: [], reason: "severe environment revocation: critical_vulnerability",
            runtime_image_digest: image.digest)
    expect(image.reload).to be_revoked
  end

  it "makes repeated revocation idempotent and does not terminate turns twice" do
    allow(Syrus::Host::AgentRuntime).to receive(:terminate_chat_processes).and_return(1)
    allow(Syrus::Host::RuntimeImages).to receive(:revoke) { |runtime_image, reason:, **| runtime_image.mark_revoked!(reason:) }
    revision.update!(state: "active", runtime_image: image)
    environment.update!(state: "active", active_revision: revision, active_runtime_image: image)
    lifecycle = described_class.new(environment)

    2.times { lifecycle.revoke!(revision, reason: "critical_vulnerability", severity: :severe) }

    expect(Syrus::Host::AgentRuntime).to have_received(:terminate_chat_processes).once
    expect(RuntimeImageAuditEvent.where(event_type: "coworker_environment.revoked",
                                        runtime_image_id: image.id).count).to eq(1)
  end

  it "refuses to broaden severe revocation when the revision has no image digest" do
    expect {
      described_class.new(environment).revoke!(revision, reason: "critical_vulnerability", severity: :severe)
    }.to raise_error(Coworkers::EnvironmentRevision::InvalidTransition, /requires an affected image digest/)

    expect(environment.reload.last_error_code).to be_nil
  end

  it "fails closed when active pointers do not match the immutable activation" do
    described_class.new(environment).reconcile_build!(revision)
    accepted_attestation(image)
    described_class.new(environment).publish!(revision, authority: publication_authority(revision))
    environment.update_column(:active_runtime_image_id, nil)

    expect { Coworkers::EnvironmentActiveSelection.resolve(environment) }
      .to raise_error(Coworkers::EnvironmentActiveSelection::InconsistentPointer)
  end

  it "rolls the entire publication back when activation history cannot be recorded" do
    described_class.new(environment).reconcile_build!(revision)
    accepted_attestation(image)
    authority = publication_authority(revision)

    expect { described_class.new(environment).publish!(revision, authority:, actor: "") }
      .to raise_error(ActiveRecord::RecordInvalid)

    expect(revision.reload).to be_candidate
    expect(environment.reload.active_revision_id).to be_nil
  end

  it "rejects authority bound to another immutable digest" do
    described_class.new(environment).reconcile_build!(revision)
    accepted_attestation(image)
    authority = publication_authority(revision)
    authority.subject.image_digest = "sha256:#{'9' * 64}"

    expect { described_class.new(environment).publish!(revision, authority:) }
      .to raise_error(Coworkers::EnvironmentRevision::InvalidTransition, /authority does not match/)
  end

  it "rejects a succeeded build whose image record is missing" do
    request.result.destroy!

    described_class.new(environment).reconcile_build!(revision)

    expect(revision.reload).to be_rejected
    expect(environment.reload).to have_attributes(state: "failed", last_error_code: "missing_image_record")
    expect(Syrus::Events).to have_received(:publish).with(
      "coworker_environment.rejected", hash_including(revision_id: revision.id)
    )
  end

  it "keeps the current active image selected when a replacement build fails" do
    active = Coworkers::EnvironmentRevision.create!(environment: environment, number: 2, state: "active",
                                                     source_digest: "sha256:#{'f' * 64}", runtime_image: image)
    environment.update!(active_revision: active, active_runtime_image: image)
    request.result.destroy!
    request.update!(state: "failed")
    RuntimeImageBuildResult.create!(request: request, outcome: "failed", error_code: "builder_failed", finished_at: Time.current)

    described_class.new(environment).reconcile_build!(revision)

    expect(revision.reload).to be_rejected
    expect(environment.reload).to have_attributes(state: "active", active_revision_id: active.id,
                                                   last_error_code: "builder_failed")
    expect(Syrus::Events).to have_received(:publish).with(
      "coworker_environment.build_failed", hash_including(revision_id: revision.id)
    )
  end

  it "persists the rejection when publishing a candidate that became incompatible" do
    described_class.new(environment).reconcile_build!(revision)
    allow(Syrus::Host::RuntimeImages).to receive(:active_base).and_return(base.with(runtime_abi: 9))

      expect { described_class.new(environment).publish!(revision, actor: "operator", authority: publication_authority(revision)) }
      .to raise_error(Coworkers::EnvironmentRevision::InvalidTransition)

    expect(revision.reload).to be_rejected
    expect(environment.reload).to have_attributes(state: "failed", candidate_revision_id: nil,
                                                   last_error_code: described_class::INCOMPATIBLE)
  end

  it "fails closed when the image ABI is incompatible" do
    allow(Syrus::Host::RuntimeImages).to receive(:active_base).and_return(base.with(runtime_abi: 9))

    described_class.new(environment).reconcile_build!(revision)

    expect(revision.reload).to be_rejected
    expect(environment.reload.last_error_code).to eq(described_class::INCOMPATIBLE)
    expect(Syrus::Events).to have_received(:publish).with(
      "coworker_environment.incompatible", hash_including(revision_id: revision.id)
    )
  end

  it "retires pointers on disable without deleting generic image history" do
    revision.update!(state: "active", runtime_image: image)
    environment.update!(state: "active", active_revision: revision, active_runtime_image: image)

    described_class.new(environment).disable!(actor: "plugin_disable")

    expect(revision.reload).to be_retired
    expect(environment.reload).to have_attributes(state: "revoked", active_revision_id: nil,
                                                   last_error_code: "coworker_disabled")
    expect(image.reload).to be_available
  end

  it "retires a verified candidate on disable instead of orphaning it" do
    revision.update!(state: "candidate", runtime_image: image)
    environment.update!(state: "candidate", candidate_revision: revision, candidate_runtime_image: image)

    described_class.new(environment).disable!(actor: "plugin_disable")

    expect(revision.reload).to be_retired
    expect(environment.reload).to have_attributes(state: "revoked", candidate_revision_id: nil)
    expect(RuntimeImageAuditEvent.where(event_type: "coworker_environment.disabled")).to exist
  end

  it "rejects a successful build projection when its image was deleted" do
    image.mark_deleted!

    described_class.new(environment).reconcile_build!(revision)

    expect(revision.reload).to be_rejected
    expect(environment.reload).to have_attributes(state: "revoked", last_error_code: "image_deleted")
    expect(RuntimeImageAuditEvent.where(event_type: "coworker_environment.revoked", runtime_image_id: image.id)).to exist
    expect(Syrus::Events).to have_received(:publish).with(
      "coworker_environment.revoked", hash_including(revision_id: revision.id)
    )
  end

  it "keeps the previous active revision selected when a replacement candidate is revoked" do
    active_image = RuntimeImage.create!(runtime_image_namespace: namespace, digest: "sha256:#{'f' * 64}",
                                        platform: "linux/amd64", source_kind: "coworker_environment",
                                        source_ref: "revision-previous", availability: "available",
                                        published_at: Time.current)
    active = Coworkers::EnvironmentRevision.create!(environment: environment, number: 2, state: "active",
                                                     source_digest: "sha256:#{'f' * 64}", runtime_image: active_image)
    revision.update!(state: "candidate", runtime_image: image)
    environment.update!(state: "candidate", active_revision: active, active_runtime_image: active_image,
                        candidate_revision: revision, candidate_runtime_image: image)
    image.mark_deleted!

    described_class.new(environment).revoke!(revision, reason: "image_deleted")

    expect(revision.reload).to be_revoked
    expect(environment.reload).to have_attributes(state: "active", active_revision_id: active.id,
                                                   active_runtime_image_id: active_image.id,
                                                   candidate_revision_id: nil, candidate_runtime_image_id: nil)
  end

  it "retains image history and audits ownership removal before deleting plugin rows" do
    revision.update!(state: "candidate", runtime_image: image)

    expect { coworker.destroy! }
      .to change { RuntimeImageAuditEvent.where(event_type: "coworker_environment.owner_removed").count }.by(1)
    expect(Syrus::Host::RuntimeImages).to have_received(:retain)
      .with(image, reason: "coworker environment audit history", actor: "coworker_removal")
    expect(image.reload).to be_available
  end
end
