require "rails_helper"

RSpec.describe SyncGithubPermissionsJob do
  it "delegates to the permission syncer when the GitHub App is registered" do
    AppSetting.current.update!(github_app_id: 42)
    syncer = instance_double(GithubPermissionSyncer, sync: nil)
    allow(GithubPermissionSyncer).to receive(:new).and_return(syncer)

    described_class.perform_now

    expect(syncer).to have_received(:sync)
  end

  it "stamps repository membership mismatch fields when run from the scheduler" do
    AppSetting.current.update!(github_app_id: 42)
    owner = Factories.user(github_handle: "owner-handle")
    installation = Factories.installation(user: owner)
    repository = Factories.repository(user: owner, owner: "acme", name: "widgets", installation: installation)
    client = instance_double(GithubClient)
    allow(GithubClient).to receive(:for).with(repository: repository).and_return(client)
    allow(client).to receive(:collaborator_permissions).with(repository.slug).and_return([])

    described_class.perform_now

    membership = repository.repository_memberships.find_by!(user: owner)
    expect(membership.reload).to have_attributes(
      github_permission_mismatch_reason: "not_a_github_collaborator",
      github_permission_mismatch_checked_at: be_present
    )
  end

  it "continues syncing after a repository has a transient connection failure" do
    AppSetting.current.update!(github_app_id: 42)
    owner = Factories.user(github_handle: "owner-handle")
    installation = Factories.installation(user: owner)
    first_repository = Factories.repository(user: owner, owner: "acme", name: "first", installation: installation)
    second_repository = Factories.repository(user: owner, owner: "acme", name: "second", installation: installation)
    first_client = instance_double(GithubClient)
    second_client = instance_double(GithubClient)
    allow(GithubClient).to receive(:for).with(repository: first_repository).and_return(first_client)
    allow(GithubClient).to receive(:for).with(repository: second_repository).and_return(second_client)
    allow(first_client).to receive(:collaborator_permissions)
      .with(first_repository.slug)
      .and_raise(Faraday::ConnectionFailed.new("end of file reached"))
    allow(second_client).to receive(:collaborator_permissions).with(second_repository.slug).and_return([])

    expect { described_class.perform_now }.not_to raise_error

    expect(second_client).to have_received(:collaborator_permissions).with(second_repository.slug)
    expect(second_repository.repository_memberships.find_by!(user: owner).github_permission_mismatch_checked_at).to be_present
  end

  it "no-ops when the GitHub App is not registered" do
    expect(GithubPermissionSyncer).not_to receive(:new)
    described_class.perform_now
  end
end
