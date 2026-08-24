require "rails_helper"

RSpec.describe GithubPermissionSyncer do
  let(:owner) { Factories.user(github_handle: "owner-handle") }
  let(:installation) { Factories.installation(user: owner) }
  let(:repository) { Factories.repository(user: owner, owner: "acme", name: "widgets", installation: installation) }
  let(:client) { instance_double(GithubClient) }
  let(:syncer) { described_class.new(client_factory: ->(_repository) { client }) }

  before do
    AppSetting.current.update!(github_app_id: 42, github_app_private_key_pem: OpenSSL::PKey::RSA.generate(2048).to_pem)
  end

  def stub_collaborators(list)
    allow(client).to receive(:collaborator_permissions).with(repository.slug).and_return(list)
  end

  describe "#sync" do
    it "skips repositories without an active installation" do
      repository.installation.update!(removed_at: Time.current)
      expect(client).not_to receive(:collaborator_permissions)

      syncer.sync
    end

    it "skips archived repositories" do
      repository.archive!
      expect(client).not_to receive(:collaborator_permissions)

      syncer.sync
    end

    it "syncs repositories with an active installation" do
      stub_collaborators([ { login: "owner-handle", permission: "admin" } ])

      syncer.sync

      membership = repository.repository_memberships.find_by!(user: owner)
      expect(membership.github_permission_mismatch_reason).to be_nil
      expect(membership.github_permission_mismatch_checked_at).to be_present
    end
  end

  describe "#sync_repository — direction 1 (Syrus write/admin, missing/weak GitHub access)" do
    it "flags a write/admin member with no github_handle" do
      member = Factories.user(github_handle: nil)
      membership = repository.repository_memberships.create!(user: member, role: "write")
      stub_collaborators([])

      syncer.sync_repository(repository)

      expect(membership.reload.github_permission_mismatch_reason).to eq("no_github_handle")
    end

    it "flags a write/admin member who isn't a GitHub collaborator at all" do
      member = Factories.user(github_handle: "ghost")
      membership = repository.repository_memberships.create!(user: member, role: "write")
      stub_collaborators([ { login: "owner-handle", permission: "admin" } ])

      syncer.sync_repository(repository)

      expect(membership.reload.github_permission_mismatch_reason).to eq("not_a_github_collaborator")
    end

    it "flags a write/admin member whose GitHub permission is below their Syrus role" do
      member = Factories.user(github_handle: "readonly-dev")
      membership = repository.repository_memberships.create!(user: member, role: "admin")
      stub_collaborators([ { login: "readonly-dev", permission: "read" } ])

      syncer.sync_repository(repository)

      expect(membership.reload.github_permission_mismatch_reason).to eq("insufficient_github_permission")
    end

    it "clears the mismatch reason once GitHub permission matches or exceeds the Syrus role" do
      member = Factories.user(github_handle: "matched-dev")
      membership = repository.repository_memberships.create!(
        user: member, role: "write",
        github_permission_mismatch_reason: "not_a_github_collaborator",
        github_permission_mismatch_checked_at: 1.day.ago
      )
      stub_collaborators([ { login: "matched-dev", permission: "admin" } ])

      syncer.sync_repository(repository)

      expect(membership.reload.github_permission_mismatch_reason).to be_nil
    end

    it "is case-insensitive when matching github_handle against the GitHub login" do
      member = Factories.user(github_handle: "MixedCase")
      membership = repository.repository_memberships.create!(user: member, role: "write")
      stub_collaborators([ { login: "mixedcase", permission: "write" } ])

      syncer.sync_repository(repository)

      expect(membership.reload.github_permission_mismatch_reason).to be_nil
    end

    it "does not touch read-tier memberships" do
      member = Factories.user(github_handle: "reader")
      membership = repository.repository_memberships.create!(user: member, role: "read")
      stub_collaborators([])

      syncer.sync_repository(repository)

      expect(membership.reload.github_permission_mismatch_checked_at).to be_nil
    end
  end

  describe "#sync_repository — direction 2 (GitHub write+, no Syrus access)" do
    it "records a discrepancy for a write-tier GitHub collaborator with no Syrus user" do
      stub_collaborators([ { login: "owner-handle", permission: "admin" }, { login: "external-dev", permission: "write" } ])

      syncer.sync_repository(repository)

      discrepancy = repository.github_collaborator_discrepancies.find_by!(github_login: "external-dev")
      expect(discrepancy.github_permission).to eq("write")
      expect(discrepancy.checked_at).to be_present
    end

    it "records a discrepancy for a write-tier GitHub collaborator whose matching Syrus user has no repository access" do
      repository
      Factories.user(github_handle: "no-access-dev")
      stub_collaborators([ { login: "owner-handle", permission: "admin" }, { login: "no-access-dev", permission: "write" } ])

      syncer.sync_repository(repository)

      expect(repository.github_collaborator_discrepancies.exists?(github_login: "no-access-dev")).to be true
    end

    it "does not record a discrepancy for a read-tier GitHub collaborator" do
      stub_collaborators([ { login: "owner-handle", permission: "admin" }, { login: "read-only-dev", permission: "read" } ])

      syncer.sync_repository(repository)

      expect(repository.github_collaborator_discrepancies).to be_empty
    end

    it "does not record a discrepancy when the GitHub collaborator already has Syrus access" do
      member = Factories.user(github_handle: "has-access-dev")
      repository.repository_memberships.create!(user: member, role: "write")
      stub_collaborators([ { login: "owner-handle", permission: "admin" }, { login: "has-access-dev", permission: "write" } ])

      syncer.sync_repository(repository)

      expect(repository.github_collaborator_discrepancies).to be_empty
    end

    it "removes stale discrepancies that are no longer mismatched" do
      stale = repository.github_collaborator_discrepancies.create!(github_login: "gone-dev", github_permission: "write", checked_at: 1.day.ago)
      stub_collaborators([ { login: "owner-handle", permission: "admin" } ])

      syncer.sync_repository(repository)

      expect(GithubCollaboratorDiscrepancy.exists?(stale.id)).to be false
    end
  end

  describe "#sync_repository — failure handling" do
    it "logs and continues instead of raising when GitHub API calls fail" do
      allow(client).to receive(:collaborator_permissions).and_raise(Octokit::Unauthorized.new)

      expect { syncer.sync_repository(repository) }.not_to raise_error
    end
  end
end
