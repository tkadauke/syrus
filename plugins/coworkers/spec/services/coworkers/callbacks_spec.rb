require "rails_helper"

RSpec.describe Coworkers::Callbacks do
  it "schedules bounded branch retention from the plugin tick" do
    allow(Coworkers::ProvisioningReconciler).to receive(:call)

    expect { described_class.on_tick }.to have_enqueued_job(Coworkers::BranchRetentionSweepJob).on_queue("plugin_coworkers")
      .and have_enqueued_job(Coworkers::EnvironmentReconcileJob).on_queue("plugin_coworkers")
  end

  it "retires active and candidate environments when the plugin is disabled" do
    owner = Factories.user
    first = Coworkers::Coworker.create!(owner_user: owner, name: "Active", handle: "disable-active",
                                        workspace_repo: "https://github.com/acme/active.git")
    second = Coworkers::Coworker.create!(owner_user: owner, name: "Candidate", handle: "disable-candidate",
                                         workspace_repo: "https://github.com/acme/candidate.git")
    active_environment = Coworkers::Environment.create!(coworker: first, state: "active")
    candidate_environment = Coworkers::Environment.create!(coworker: second, state: "candidate")
    active = Coworkers::EnvironmentRevision.create!(environment: active_environment, number: 1, state: "active",
                                                     source_digest: "sha256:#{'a' * 64}")
    candidate = Coworkers::EnvironmentRevision.create!(environment: candidate_environment, number: 1, state: "candidate",
                                                        source_digest: "sha256:#{'b' * 64}")
    active_environment.update!(active_revision: active)
    candidate_environment.update!(candidate_revision: candidate)

    described_class.on_disable

    expect(active.reload).to be_retired
    expect(candidate.reload).to be_retired
    expect(active_environment.reload).to have_attributes(state: "revoked", active_revision_id: nil,
                                                          last_error_code: "coworker_disabled")
    expect(candidate_environment.reload).to have_attributes(state: "revoked", candidate_revision_id: nil,
                                                             last_error_code: "coworker_disabled")
  end
end
