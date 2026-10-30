require "rails_helper"

RSpec.describe Coworkers::ProvisioningCleanup do
  class ProvisioningRemote
    attr_accessor :sha, :failure
    attr_reader :deleted
    def branch_sha(_branch) = sha
    def delete_if_matches!(branch, expected_sha:)
      raise failure if failure
      raise Coworkers::RemoteWorkspace::RefChanged, "changed" unless sha == expected_sha
      @deleted = branch
      self.sha = nil
    end
  end

  let(:owner) { Factories.user }
  let(:remote) { ProvisioningRemote.new.tap { |value| value.sha = "a" * 40 } }
  let(:attempt) do
    Coworkers::ProvisioningAttempt.create!(owner_user: owner, idempotency_key: SecureRandom.uuid,
      remote_owner: "acme", remote_name: "homes", handle: "maya", branch: "coworkers/maya",
      expected_seeded_commit: "a" * 40, state: "cleanup_pending")
  end

  it "retries a remote failure and then cleans the exact seeded ref idempotently" do
    remote.failure = RuntimeError.new("token https://x-access-token:secret@github.com/acme/homes.git")
    expect { described_class.call(attempt, remote_workspace: remote) }.to raise_error(RuntimeError)
    expect(attempt.reload).to have_attributes(state: "cleanup_pending", retry_count: 1)
    expect(attempt.last_error).not_to include("secret")

    remote.failure = nil
    expect(described_class.call(attempt, remote_workspace: remote).state).to eq("cleaned")
    expect(remote.deleted).to eq("coworkers/maya")
    expect(described_class.call(attempt, remote_workspace: remote).state).to eq("cleaned")
  end

  it "refuses cleanup when the SHA changed" do
    remote.sha = "b" * 40
    expect(described_class.call(attempt, remote_workspace: remote).state).to eq("manual_attention")
    expect(remote.deleted).to be_nil
  end


  it "refuses cleanup when the ref changes after inspection but before deletion" do
    allow(remote).to receive(:delete_if_matches!) do |branch, expected_sha:|
      remote.sha = "b" * 40
      raise Coworkers::RemoteWorkspace::RefChanged, "the remote ref changed before cleanup could delete it" unless remote.sha == expected_sha
    end

    expect(described_class.call(attempt, remote_workspace: remote).state).to eq("manual_attention")
    expect(remote.sha).to eq("b" * 40)
    expect(remote.deleted).to be_nil
  end

  it "refuses cleanup when a completed coworker claims the handle" do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya",
      workspace_repo: "https://github.com/acme/homes.git", role_summary: "Engineer")
    expect(described_class.call(attempt, remote_workspace: remote).state).to eq("manual_attention")
    expect(remote.deleted).to be_nil
  end

  it "guards the one-time known orphan recovery by handle, ownership, and expected SHA" do
    wrong = ProvisioningRemote.new.tap { |value| value.sha = "b" * 40 }
    recovered = Coworkers::KnownOrphanRecovery.call(owner: owner, remote_owner: "acme", remote_name: "homes",
      expected_sha: "a" * 40, remote_workspace: wrong)
    expect(recovered.state).to eq("manual_attention")
    expect(wrong.deleted).to be_nil

    Coworkers::Coworker.create!(owner_user: owner, name: "Gilfoyle", handle: "gilfoyle",
      workspace_repo: "https://github.com/acme/homes.git", role_summary: "Engineer")
    expect {
      Coworkers::KnownOrphanRecovery.call(owner: owner, remote_owner: "acme", remote_name: "homes",
        expected_sha: "a" * 40, remote_workspace: remote)
    }.to raise_error(Coworkers::ProvisioningCleanup::UnsafeCleanup)
  end
end
