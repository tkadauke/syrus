require "rails_helper"

RSpec.describe "API: /api/v1/app/credentials", type: :request do
  let(:user) do
    Factories.user(
      claude_oauth_token: "sk-existing",
      codex_api_key: "sk-codex-existing",
      codex_auth_json: Factories.codex_auth_json(access_token: "codex-access-existing"),
      github_token: "ghp_existing"
    )
  end

  def parse_body
    JSON.parse(response.body)
  end

  def upload_file(name: "notes.txt", content_type: "text/plain", content: "notes")
    file = Tempfile.new([ "document", File.extname(name) ])
    file.binmode
    file.write(content)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, content_type, original_filename: name)
  end

  it "401s with a JSON error when signed out" do
    user
    get "/api/v1/app/credentials"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "shows credential status without echoing encrypted secret values" do
    sign_in_as(user)

    get "/api/v1/app/credentials"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("user", "email_address")).to eq(user.email_address)
    expect(body["credential_status"]).to include(
      "claude_oauth_token" => true,
      "codex_api_key" => true,
      "codex_auth_json" => true,
      "github_token" => true
    )
    expect(body).not_to have_key("documents")
    expect(response.body).not_to include("sk-existing")
    expect(response.body).not_to include("sk-codex-existing")
    expect(response.body).not_to include("codex-access-existing")
    expect(response.body).not_to include("ghp_existing")
  end

  it "lists personal documents separately from credentials" do
    sign_in_as(user)
    user.documents.create!(
      kind: "google_doc",
      google_doc_url: "https://docs.google.com/document/d/user/edit",
      user: user
    )

    get "/api/v1/app/credentials/documents"

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("documents", 0, "google_doc_url")).to eq("https://docs.google.com/document/d/user/edit")
  end

  it "updates write-only credentials while preserving blank secrets and false booleans" do
    sign_in_as(user)
    user.update!(scheduling_paused: true)

    patch "/api/v1/app/credentials", params: {
      user: {
        claude_oauth_token: "sk-new",
        codex_api_key: "",
        codex_auth_json: "",
        github_token: "",
        scheduling_paused: false,
        agent_max_turns: "500"
      }
    }

    expect(response).to have_http_status(:ok)
    user.reload
    expect(user.claude_oauth_token).to eq("sk-new")
    expect(user.codex_api_key).to eq("sk-codex-existing")
    expect(user.codex_auth_json).to include("codex-access-existing")
    expect(user.github_token).to eq("ghp_existing")
    expect(user.scheduling_paused).to be false
    expect(user.agent_max_turns).to eq(500)
    expect(parse_body["message"]).to eq("Credentials updated.")
  end

  it "updates team-visible profile fields" do
    sign_in_as(user)

    patch "/api/v1/app/credentials", params: {
      user: {
        name: "",
        first_name: "Ada",
        last_name: "Lovelace",
        github_handle: "@ada",
        profile_bio: "Keeps the machines honest.",
        profile_location: " London ",
        profile_company: " Analytical Engines Ltd ",
        profile_website: "https://example.com/ada",
        avatar_url: "https://example.com/ada.png"
      }
    }

    expect(response).to have_http_status(:ok)
    user.reload
    expect(user.display_name).to eq("Ada Lovelace")
    expect(user.github_handle).to eq("ada")
    expect(user.profile_bio).to eq("Keeps the machines honest.")
    expect(user.profile_location).to eq("London")
    expect(user.profile_company).to eq("Analytical Engines Ltd")
    expect(user.profile_website).to eq("https://example.com/ada")
    expect(parse_body["user"]).to include(
      "first_name" => "Ada",
      "last_name" => "Lovelace",
      "display_name" => "Ada Lovelace",
      "github_handle" => "ada",
      "profile_location" => "London",
      "profile_company" => "Analytical Engines Ltd",
      "profile_website" => "https://example.com/ada",
      "avatar_url" => "https://example.com/ada.png"
    )
  end

  it "clears blank profile fields without clearing blank write-only credentials" do
    sign_in_as(user)
    user.update!(profile_company: "Analytical Engines Ltd", profile_bio: "Notes")

    patch "/api/v1/app/credentials", params: {
      user: {
        profile_company: "",
        profile_bio: "",
        github_token: ""
      }
    }

    expect(response).to have_http_status(:ok)
    user.reload
    expect(user.profile_company).to be_nil
    expect(user.profile_bio).to be_nil
    expect(user.github_token).to eq("ghp_existing")
  end

  it "returns validation errors" do
    sign_in_as(user)

    patch "/api/v1/app/credentials", params: {
      user: { agent_provider: "oracle" }
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
    expect(parse_body.dig("error", "message")).to include("Agent provider")
  end

  it "clears known credentials" do
    sign_in_as(user)

    post "/api/v1/app/credentials/clear_credential", params: { credential: "github_token" }

    expect(response).to have_http_status(:ok)
    expect(user.reload.github_token).to be_nil
    expect(parse_body["message"]).to eq("GitHub token cleared.")
    expect(parse_body.dig("credential_status", "github_token")).to be false
  end

  it "uploads and deletes personal documents" do
    sign_in_as(user)

    expect {
      post "/api/v1/app/credentials/documents", params: {
        document: {
          files: [ upload_file ],
          google_doc_url: "https://docs.google.com/document/d/user/edit"
        }
      }
    }.to change(Document, :count).by(2)

    expect(response).to have_http_status(:created)
    body = parse_body
    expect(body["documents"].map { |document| document["kind"] }).to contain_exactly("file", "google_doc")

    document = user.documents.find_by!(kind: "google_doc")
    delete "/api/v1/app/credentials/documents/#{document.id}"

    expect(response).to have_http_status(:ok)
    expect(Document.where(id: document.id)).not_to exist
    expect(parse_body["message"]).to eq("Document removed.")
  end

  it "rotates and revokes admin API tokens" do
    sign_in_as(user)

    post "/api/v1/app/credentials/rotate_api_token"

    expect(response).to have_http_status(:ok)
    expect(parse_body["new_api_token"]).to start_with("syrus_")
    expect(user.reload.api_token).to start_with("syrus_")
    expect(parse_body.dig("credential_status", "api_token")).to be true

    delete "/api/v1/app/credentials/revoke_api_token"

    expect(response).to have_http_status(:ok)
    expect(user.reload.api_token).to be_nil
    expect(parse_body.dig("credential_status", "api_token")).to be false
  end

  it "rejects API token actions for non-admins" do
    admin = user
    non_admin = Factories.user
    expect(admin).to be_admin
    expect(non_admin).not_to be_admin
    sign_in_as(non_admin)

    post "/api/v1/app/credentials/rotate_api_token"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
    expect(non_admin.reload.api_token).to be_nil
  end
end
