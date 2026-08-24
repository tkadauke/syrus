require "rails_helper"

RSpec.describe SyncGithubPermissionsJob do
  it "delegates to the permission syncer when the GitHub App is registered" do
    AppSetting.current.update!(github_app_id: 42)
    syncer = instance_double(GithubPermissionSyncer, sync: nil)
    allow(GithubPermissionSyncer).to receive(:new).and_return(syncer)

    described_class.perform_now

    expect(syncer).to have_received(:sync)
  end

  it "no-ops when the GitHub App is not registered" do
    expect(GithubPermissionSyncer).not_to receive(:new)
    described_class.perform_now
  end
end
