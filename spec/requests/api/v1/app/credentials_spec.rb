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
    expect(body.dig("user", "chat_provider")).to be_nil
    expect(body.dig("options", "chat_providers")).to eq(%w[claude codex])
    expect(body.dig("user", "role")).to eq("developer")
    expect(body.dig("options", "roles")).to eq(%w[ developer product_owner ])
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
        agent_max_turns: "500",
        role: "product_owner"
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
    expect(user.role).to eq("product_owner")
    expect(parse_body["message"]).to eq("Credentials updated.")
  end

  it "updates desktop notification preferences without replacing the full preferences hash" do
    sign_in_as(user)
    user.update_column(:notification_preferences, { "desktop_job_failed" => true, "epic_completed" => true, "unknown_future_key" => false })

    patch "/api/v1/app/credentials", params: {
      user: {
        notification_preferences: {
          desktop_job_implemented: false
        }
      }
    }

    expect(response).to have_http_status(:ok)
    user.reload
    expect(user.desktop_notification_enabled?(:desktop_job_implemented)).to be(false)
    expect(user.desktop_notification_enabled?(:desktop_job_failed)).to be(true)
    expect(user.notification_preference_for(:epic_completed)).to be(true)
    expect(user.read_attribute(:notification_preferences)).to include("unknown_future_key" => false)
    expect(parse_body.dig("user", "notification_preferences")).to eq(
      "desktop_job_implemented" => false,
      "desktop_job_failed" => true
    )
  end

  it "updates the selected chat provider" do
    sign_in_as(user)

    patch "/api/v1/app/credentials", params: {
      user: { chat_provider: "codex" }
    }

    expect(response).to have_http_status(:ok)
    expect(user.reload.chat_provider).to eq("codex")
    expect(parse_body.dig("user", "chat_provider")).to eq("codex")
  end

  it "only lists configured chat providers" do
    user.update!(codex_auth_mode: "api_key", codex_api_key: nil, codex_auth_json: nil)
    sign_in_as(user)

    get "/api/v1/app/credentials"

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("options", "chat_providers")).to eq([ "claude" ])
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
      "profile_bio" => "Keeps the machines honest.",
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

  it "tests a configured credential and returns the provider result" do
    sign_in_as(user)
    result = CredentialProbe::Result.new(
      credential: "github_token",
      ok: true,
      message: "GitHub token is valid for ada.",
      details: { login: "ada", scopes: [ "repo" ] }
    )
    expect(CredentialProbe).to receive(:call)
      .with(user: user, credential: "github_token")
      .and_return(result)

    post "/api/v1/app/credentials/test_credential", params: { credential: "github_token" }

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("GitHub token is valid for ada.")
    expect(parse_body["credential_test"]).to eq(
      "credential" => "github_token",
      "ok" => true,
      "message" => "GitHub token is valid for ada.",
      "details" => {
        "login" => "ada",
        "scopes" => [ "repo" ]
      }
    )
    expect(response.body).not_to include("ghp_existing")
  end

  it "rejects unknown credential tests" do
    sign_in_as(user)

    post "/api/v1/app/credentials/test_credential", params: { credential: "api_token" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("unknown_credential")
  end

  it "tests an unsaved GitHub token against the required scopes" do
    sign_in_as(user)
    result = CredentialProbe::Result.new(
      credential: "github_token",
      ok: true,
      message: "Token is valid for ada.",
      details: { login: "ada", scopes: %w[ repo workflow ], missing_scopes: [] }
    )
    expect(CredentialProbe).to receive(:github_token)
      .with(token: "ghp_pasted", required_scopes: %w[ repo workflow ])
      .and_return(result)

    post "/api/v1/app/credentials/test_github_token", params: { github_token: "ghp_pasted" }

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Token is valid for ada.")
    expect(parse_body.dig("credential_test", "ok")).to be true
    # The pasted token is never persisted by a test.
    expect(user.reload.github_token).to eq("ghp_existing")
  end

  it "preflights whether claude already works on this machine" do
    sign_in_as(user)
    result = CredentialProbe::Result.new(
      credential: "claude_oauth_token",
      ok: true,
      message: "Claude already works on this machine — no token needed.",
      details: {}
    )
    expect(CredentialProbe).to receive(:claude_cli_ready).with(user: user).and_return(result)

    post "/api/v1/app/credentials/test_claude_cli"

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("credential_test", "ok")).to be true
  end

  it "starts the Claude OAuth flow using the provider paste callback" do
    sign_in_as(user)

    post "/api/v1/app/credentials/claude_oauth_start"

    expect(response).to have_http_status(:ok)
    authorize_url = parse_body["authorize_url"]
    expect(authorize_url).to start_with(ClaudeOauth::AUTHORIZE_URL)
    params = Rack::Utils.parse_query(URI(authorize_url).query)
    expect(params["redirect_uri"]).to eq(ClaudeOauth::PASTE_REDIRECT_URI)
    expect(params["code_challenge_method"]).to eq("S256")
  end

  it "exchanges a pasted code, saves the token, and tests it" do
    sign_in_as(user)
    post "/api/v1/app/credentials/claude_oauth_start"

    stub_request(:post, ClaudeOauth::TOKEN_URL)
      .to_return(status: 200, body: { access_token: "sk-ant-oat01-new" }.to_json, headers: { "Content-Type" => "application/json" })
    probe = CredentialProbe::Result.new(credential: "claude_oauth_token", ok: true, message: "Claude OAuth token is valid.", details: {})
    expect(CredentialProbe).to receive(:call).with(user: user, credential: "claude_oauth_token").and_return(probe)

    post "/api/v1/app/credentials/claude_oauth_exchange", params: { code: "auth-code#state" }

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("credential_test", "ok")).to be true
    expect(user.reload.claude_oauth_token).to eq("sk-ant-oat01-new")
  end

  it "rejects an exchange that was never started" do
    sign_in_as(user)

    post "/api/v1/app/credentials/claude_oauth_exchange", params: { code: "x" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("oauth_not_started")
  end

  it "saves a long-lived token directly when a sk-ant- value is pasted instead of an auth code" do
    sign_in_as(user)
    post "/api/v1/app/credentials/claude_oauth_start"

    probe = CredentialProbe::Result.new(credential: "claude_oauth_token", ok: true, message: "Claude OAuth token is valid.", details: {})
    expect(CredentialProbe).to receive(:call).with(user: user, credential: "claude_oauth_token").and_return(probe)

    post "/api/v1/app/credentials/claude_oauth_exchange", params: { code: "sk-ant-oat01-direct-token" }

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("credential_test", "ok")).to be true
    expect(user.reload.claude_oauth_token).to eq("sk-ant-oat01-direct-token")
  end

  it "saves a long-lived token directly even without a prior oauth start" do
    sign_in_as(user)

    probe = CredentialProbe::Result.new(credential: "claude_oauth_token", ok: true, message: "Claude OAuth token is valid.", details: {})
    expect(CredentialProbe).to receive(:call).with(user: user, credential: "claude_oauth_token").and_return(probe)

    post "/api/v1/app/credentials/claude_oauth_exchange", params: { code: "sk-ant-oat01-no-flow-needed" }

    expect(response).to have_http_status(:ok)
    expect(user.reload.claude_oauth_token).to eq("sk-ant-oat01-no-flow-needed")
  end

  it "starts the Codex OAuth flow using the CLI paste callback" do
    sign_in_as(user)
    expect(CodexOauth).to receive(:start_callback_listener).with(user: user).and_return(true)

    post "/api/v1/app/credentials/codex_oauth_start"

    expect(response).to have_http_status(:ok)
    expect(parse_body["listener_started"]).to be true
    authorize_url = parse_body["authorize_url"]
    expect(authorize_url).to start_with(CodexOauth::AUTHORIZE_URL)
    params = Rack::Utils.parse_query(URI(authorize_url).query)
    expect(params["redirect_uri"]).to eq(CodexOauth::PASTE_REDIRECT_URI)
    expect(params["code_challenge_method"]).to eq("S256")
    expect(params["scope"]).to eq(CodexOauth::SCOPE)
  end

  it "exchanges a pasted Codex code, saves auth.json, switches mode, and tests it" do
    sign_in_as(user)
    allow(CodexOauth).to receive(:start_callback_listener).and_return(true)
    post "/api/v1/app/credentials/codex_oauth_start"
    state = Rack::Utils.parse_query(URI(parse_body["authorize_url"]).query)["state"]

    stub_request(:post, CodexOauth::TOKEN_URL)
      .to_return(
        status: 200,
        body: {
          id_token: "id-token-new",
          access_token: "access-token-new",
          refresh_token: "refresh-token-new"
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
    probe = CredentialProbe::Result.new(credential: "codex_auth_json", ok: true, message: "Codex ChatGPT auth.json is valid.", details: {})
    expect(CredentialProbe).to receive(:call).with(user: user, credential: "codex_auth_json").and_return(probe)

    post "/api/v1/app/credentials/codex_oauth_exchange", params: { code: "auth-code##{state}" }

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("credential_test", "ok")).to be true
    expect(user.reload.codex_auth_mode).to eq("chatgpt_login")
    saved = JSON.parse(user.codex_auth_json)
    expect(saved["auth_mode"]).to eq("chatgpt")
    expect(saved.dig("tokens", "access_token")).to eq("access-token-new")
  end

  it "rejects a Codex exchange that was never started" do
    sign_in_as(user)

    post "/api/v1/app/credentials/codex_oauth_exchange", params: { code: "x" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("oauth_not_started")
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

  it "returns locale in the credentials payload" do
    user.update!(locale: "de")
    sign_in_as(user)

    get "/api/v1/app/credentials"

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("user", "locale")).to eq("de")
  end

  it "updates the user locale via PATCH" do
    sign_in_as(user)

    patch "/api/v1/app/credentials", params: { user: { locale: "la" } }

    expect(response).to have_http_status(:ok)
    expect(user.reload.locale).to eq("la")
    expect(parse_body.dig("user", "locale")).to eq("la")
  end

  it "rejects invalid locales" do
    sign_in_as(user)

    patch "/api/v1/app/credentials", params: { user: { locale: "klingon" } }

    expect(response).to have_http_status(:unprocessable_content)
  end

  it "returns available locales in credentials options" do
    sign_in_as(user)

    get "/api/v1/app/credentials"

    expect(parse_body.dig("options", "locales")).to eq(%w[en de la])
  end
end
