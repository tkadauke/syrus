require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/users", type: :request do
  let!(:admin) { Factories.user }
  let(:non_admin) { Factories.user }

  def parse_body
    JSON.parse(response.body)
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/admin/users"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "403s with a JSON error for non-admin users" do
    sign_in_as(non_admin)

    get "/api/v1/app/admin/users"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "returns filtered user rows without plaintext tokens" do
    sign_in_as(admin)
    low = Factories.user(email_address: "low@example.com",
                         github_token: "ghp_secret",
                         gh_rate_limit_remaining: 5,
                         gh_rate_limit_limit: 5_000)
    Factories.user(email_address: "ok@example.com",
                   gh_rate_limit_remaining: 4_500,
                   gh_rate_limit_limit: 5_000)

    get "/api/v1/app/admin/users", params: { gh_rate: "low" }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["users"].map { |user| user["id"] }).to include(low.id)
    expect(body["users"].map { |user| user["email_address"] }).not_to include("ok@example.com")
    expect(body["filters"]).to eq("gh_rate" => "low")
    expect(body["filter"]).to eq(
      "and" => [
        { "field" => "gh_rate", "op" => "is", "value" => "low" }
      ]
    )
    expect(body.dig("controls", "filter_schema").map { |field| field["field"] }).to include("email", "gh_rate")
    rate_folder = body["smart_folders"].find { |folder| folder["name"] == "Rate limit low" }
    expect(rate_folder).to include(
      "subject_type" => "admin_user",
      "count" => 1,
      "filter" => {
        "and" => [
          { "field" => "gh_rate", "op" => "is", "value" => "low" }
        ]
      },
      "path" => a_string_matching(%r{\A/admin/users\?smart_folder_id=})
    )
    expect(response.body).not_to include("ghp_secret")
  end

  it "applies admin user smart folders" do
    sign_in_as(admin)
    SmartFolder.ensure_admin_user_builtins!
    missing_token = Factories.user(email_address: "missing@example.com", github_token: nil)
    Factories.user(email_address: "token@example.com", github_token: "ghp_secret")
    folder = SmartFolder.for_subject(:admin_user).find_by!(name: "Missing GitHub token")

    get "/api/v1/app/admin/users", params: { smart_folder_id: folder.id }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["active_smart_folder_id"]).to eq(folder.id)
    expect(body["users"].map { |user| user["id"] }).to include(missing_token.id)
    expect(body["users"].map { |user| user["email_address"] }).not_to include("token@example.com")
    active_folder = body["smart_folders"].find { |row| row["id"] == folder.id }
    expect(active_folder).to include("active" => true, "count" => be >= 1)
  end

  it "returns the active user-defined folder filter when no URL filter is present" do
    sign_in_as(admin)
    folder_tree = {
      "and" => [
        { "field" => "email", "op" => "contains", "value" => "folder" }
      ]
    }
    folder = admin.smart_folders.create!(
      name: "Folder users",
      kind: "user_defined",
      subject_type: "admin_user",
      filter: folder_tree,
      position: 0
    )
    folder_user = Factories.user(email_address: "folder@example.com")
    Factories.user(email_address: "other@example.com")

    get "/api/v1/app/admin/users", params: { smart_folder_id: folder.id }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["filter"]).to eq(folder_tree)
    expect(body["users"].map { |user| user["id"] }).to include(folder_user.id)
  end

  it "returns only the URL filter when a user-defined folder also has q" do
    sign_in_as(admin)
    folder_tree = {
      "and" => [
        { "field" => "email", "op" => "contains", "value" => "folder" }
      ]
    }
    url_tree = {
      "and" => [
        { "field" => "email", "op" => "contains", "value" => "url" }
      ]
    }
    folder = admin.smart_folders.create!(
      name: "Folder users",
      kind: "user_defined",
      subject_type: "admin_user",
      filter: folder_tree,
      position: 0
    )
    Factories.user(email_address: "folder@example.com")
    url_user = Factories.user(email_address: "url@example.com")

    get "/api/v1/app/admin/users", params: { smart_folder_id: folder.id, q: Filters::QueryParam.encode(url_tree) }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["filter"]).to eq(url_tree)
    expect(body["users"].map { |user| user["id"] }).to include(url_user.id)
  end

  it "returns user detail" do
    sign_in_as(admin)
    target = Factories.user(email_address: "target@example.com",
                            name: "Target User",
                            gh_rate_limit_remaining: 100,
                            gh_rate_limit_limit: 5_000,
                            gh_rate_limit_resource: "core")

    get "/api/v1/app/admin/users/#{target.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include(
      "id" => target.id,
      "display_name" => "Target User",
      "email_address" => "target@example.com",
      "role" => "developer",
      "scheduling_paused" => false
    )
    expect(parse_body["github_rate_limit"]).to include(
      "remaining" => 100,
      "limit" => 5_000,
      "resource" => "core"
    )
  end

  it "does not expose private chat or whiteboard records on user detail" do
    sign_in_as(admin)
    target = Factories.user(email_address: "target@example.com")
    chat = ChatSession.create!(user: target, title: "Private planning chat")
    chat.messages.create!(role: "user", content: { "text" => "Private transcript text" })
    chat.create_whiteboard!(
      scene_json: { "elements" => [ { "id" => "private-whiteboard-box" } ], "appState" => {}, "files" => {} },
      version: 2
    )

    get "/api/v1/app/admin/users/#{target.id}"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.keys).not_to include("chat_sessions", "chats", "whiteboards")
    expect(response.body).not_to include("Private planning chat")
    expect(response.body).not_to include("Private transcript text")
    expect(response.body).not_to include("private-whiteboard-box")
  end

  it "pauses and resumes scheduling for a user" do
    sign_in_as(admin)
    target = Factories.user(email_address: "target@example.com")

    expect {
      post "/api/v1/app/admin/users/#{target.id}/pause_scheduling"
    }.to change { target.reload.scheduling_paused }.from(false).to(true)
    expect(response).to have_http_status(:ok)
    expect(parse_body["scheduling_paused"]).to be true
    expect(AdminAction.where(action: "pause_user_scheduling").count).to eq(1)

    expect {
      post "/api/v1/app/admin/users/#{target.id}/unpause_scheduling"
    }.to change { target.reload.scheduling_paused }.from(true).to(false)
    expect(response).to have_http_status(:ok)
    expect(parse_body["scheduling_paused"]).to be false
    expect(AdminAction.where(action: "unpause_user_scheduling").count).to eq(1)
  end

  it "updates a user's role" do
    sign_in_as(admin)
    target = Factories.user(email_address: "target@example.com")

    expect {
      patch "/api/v1/app/admin/users/#{target.id}", params: { user: { role: "product_owner" } }
    }.to change { target.reload.role }.from("developer").to("product_owner")

    expect(response).to have_http_status(:ok)
    expect(parse_body["role"]).to eq("product_owner")
    expect(AdminAction.where(action: "update_user_role").count).to eq(1)
  end
end
