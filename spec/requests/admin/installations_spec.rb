require "rails_helper"

RSpec.describe "Admin installations health", type: :request do
  let(:admin) { Factories.user }

  before { sign_in_as(admin) }

  it "shows a manifest CTA when the GitHub App is not registered" do
    get admin_installations_path

    expect(response).to be_successful
    expect(response.body).to include("Syrus App is not registered yet.")
    expect(response.body).to include("Run manifest flow")
  end

  it "lists repositories in App and PAT columns" do
    AppSetting.current.update!(github_app_id: 123, github_app_slug: "operator-syrus")
    installation = Factories.installation(user: admin, account_login: "acme")
    app_repo = Factories.repository(
      user: admin,
      owner: "acme",
      name: "app-repo",
      installation: installation,
      github_owner_id: 100,
      github_repository_id: 200
    )
    pat_repo = Factories.repository(
      user: admin,
      owner: "globex",
      name: "pat-repo",
      github_owner_id: 101,
      github_repository_id: 201
    )

    get admin_installations_path

    expect(response.body).to include(app_repo.slug)
    expect(response.body).to include(pat_repo.slug)
    expect(response.body).to include("Active")
    expect(response.body).to include("Fallback")
    expect(response.body).to include(
      "https://github.com/apps/operator-syrus/installations/new/permissions?target_id=101&amp;repository_ids[]=201"
    )
  end

  it "queues an immediate installation refresh" do
    expect {
      post admin_installations_refresh_path
    }.to have_enqueued_job(SyncInstallationsJob).with(admin.id)

    expect(response).to redirect_to(admin_installations_path)
  end
end
