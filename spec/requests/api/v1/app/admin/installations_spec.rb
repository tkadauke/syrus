require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/installations", type: :request do
  let!(:admin) { Factories.user }
  let(:non_admin) { Factories.user }

  def parse_body
    JSON.parse(response.body)
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/admin/installations"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "403s with a JSON error for non-admin users" do
    sign_in_as(non_admin)

    get "/api/v1/app/admin/installations"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "returns repository credential status and PAT owner install links" do
    sign_in_as(admin)
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
    other_user = Factories.user(email_address: "teammate@example.com")
    # Repos are globally unique by [owner, name]; other users connect via membership.
    # Use a distinct name under the same owner to test that admin sees repos from all users.
    other_user_repo = Factories.repository(
      user: other_user,
      owner: "globex",
      name: "other-pat-repo",
      github_owner_id: 101,
      github_repository_id: 202
    )

    get "/api/v1/app/admin/installations"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body).to include(
      "github_app_registered" => true,
      "github_app_slug" => "operator-syrus"
    )
    app_row = body["repositories"].find { |repository| repository["id"] == app_repo.id }
    pat_row = body["repositories"].find { |repository| repository["id"] == pat_repo.id }
    other_row = body["repositories"].find { |repository| repository["id"] == other_user_repo.id }
    expect(app_row).to include(
      "slug" => app_repo.slug,
      "owner_user" => include("id" => admin.id, "email_address" => admin.email_address),
      "app_credential_active" => true,
      "credential_mode" => "app"
    )
    expect(pat_row).to include(
      "slug" => pat_repo.slug,
      "owner_user" => include("id" => admin.id, "email_address" => admin.email_address),
      "app_credential_active" => false,
      "credential_mode" => "pat"
    )
    expect(other_row).to include(
      "slug" => "globex/other-pat-repo",
      "owner_user" => include("id" => other_user.id, "email_address" => "teammate@example.com")
    )
    expect(body["pat_owner_groups"].first).to include(
      "owner" => "globex",
      "repository_count" => 2,
      "install_url" => "https://github.com/apps/operator-syrus/installations/new/permissions?target_id=101&repository_ids[]=202&repository_ids[]=201"
    )
  end

  it "queues an immediate installation refresh" do
    sign_in_as(admin)

    expect {
      post "/api/v1/app/admin/installations/refresh"
    }.to have_enqueued_job(SyncInstallationsJob).with(admin.id)

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Installation sync queued.")
  end
end
