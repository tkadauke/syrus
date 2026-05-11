require "rails_helper"

RSpec.describe SyncInstallationsJob do
  it "delegates to the installation syncer when the GitHub App is registered" do
    AppSetting.current.update!(github_app_id: 42)
    syncer = instance_double(GithubAppInstallationSyncer, sync: [])
    allow(GithubAppInstallationSyncer).to receive(:new).and_return(syncer)

    described_class.perform_now

    expect(syncer).to have_received(:sync)
  end

  it "no-ops when the GitHub App is not registered" do
    expect(GithubAppInstallationSyncer).not_to receive(:new)
    described_class.perform_now
  end
end
