require "rails_helper"

RSpec.describe "Credentials", type: :request do
  let(:user) do
    Factories.user(claude_oauth_token: "sk-existing",
                   codex_api_key: "sk-codex-existing",
                   codex_auth_json: Factories.codex_auth_json(access_token: "codex-access-existing"),
                   github_token: "ghp_existing",
                   telegram_chat_id: "123456")
  end

  it "requires authentication" do
    user  # force a User to exist; first-run setup redirects to new_user instead
    get edit_credentials_path
    expect(response).to redirect_to(new_session_path)
  end

  context "signed in" do
    before { sign_in_as(user) }

    def credentials_document
      Nokogiri::HTML(response.body)
    end

    def agent_section(target)
      credentials_document.at_css(%([data-credentials-form-target="#{target}"]))
    end

    def disabled_field?(selector)
      credentials_document.at_css(selector).attribute("disabled").present?
    end

    it "renders the edit form without echoing existing values" do
      get edit_credentials_path
      expect(response).to be_successful
      expect(response.body).not_to include("sk-existing")
      expect(response.body).not_to include("sk-codex-existing")
      expect(response.body).not_to include("codex-access-existing")
      expect(response.body).not_to include("ghp_existing")
      expect(response.body).not_to include("123456")
      expect(response.body).to include("Blank update fields will not clear it")
      expect(response.body).to include("Currently set")
    end

    it "renders only the selected agent's credential fields" do
      get edit_credentials_path

      expect(agent_section("claudeSection")["class"].to_s.split).not_to include("hidden")
      expect(disabled_field?("#user_claude_oauth_token")).to be(false)

      expect(agent_section("codexAuthModeSection")["class"].to_s.split).to include("hidden")
      expect(disabled_field?("#user_codex_auth_mode")).to be(true)
      expect(agent_section("codexApiKeySection")["class"].to_s.split).to include("hidden")
      expect(disabled_field?("#user_codex_api_key")).to be(true)
      expect(agent_section("codexAuthJsonSection")["class"].to_s.split).to include("hidden")
      expect(disabled_field?("#user_codex_auth_json")).to be(true)
    end

    it "renders only the selected Codex auth method's credential field" do
      user.update!(agent_provider: "codex", codex_auth_mode: "chatgpt_login")

      get edit_credentials_path

      expect(agent_section("claudeSection")["class"].to_s.split).to include("hidden")
      expect(disabled_field?("#user_claude_oauth_token")).to be(true)
      expect(agent_section("codexAuthModeSection")["class"].to_s.split).not_to include("hidden")
      expect(disabled_field?("#user_codex_auth_mode")).to be(false)
      expect(agent_section("codexApiKeySection")["class"].to_s.split).to include("hidden")
      expect(disabled_field?("#user_codex_api_key")).to be(true)
      expect(agent_section("codexAuthJsonSection")["class"].to_s.split).not_to include("hidden")
      expect(disabled_field?("#user_codex_auth_json")).to be(false)
    end

    it "offers a no-agent selection whose initial state hides every agent credential section" do
      patch credentials_path, params: { user: { agent_provider: "oracle" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(credentials_document.at_css("#user_agent_provider option[value='']")).to be_present
      expect(agent_section("claudeSection")["class"].to_s.split).to include("hidden")
      expect(agent_section("codexAuthModeSection")["class"].to_s.split).to include("hidden")
      expect(agent_section("codexApiKeySection")["class"].to_s.split).to include("hidden")
      expect(agent_section("codexAuthJsonSection")["class"].to_s.split).to include("hidden")
    end

    it "updates only non-blank fields (write-only)" do
      patch credentials_path, params: {
        user: {
          claude_oauth_token: "sk-new",
          codex_api_key: "",
          codex_auth_json: "",
          github_token: ""
        }
      }
      expect(response).to redirect_to(edit_credentials_path)
      user.reload
      expect(user.claude_oauth_token).to eq("sk-new")
      expect(user.codex_api_key).to eq("sk-codex-existing")
      expect(user.codex_auth_json).to include("codex-access-existing")
      expect(user.github_token).to eq("ghp_existing")
      expect(user.telegram_chat_id).to eq("123456")
    end

    it "leaves both unchanged when both fields are blank" do
      patch credentials_path, params: { user: { claude_oauth_token: "", codex_api_key: "", codex_auth_json: "", github_token: "", telegram_chat_id: "" } }
      user.reload
      expect(user.claude_oauth_token).to eq("sk-existing")
      expect(user.codex_api_key).to eq("sk-codex-existing")
      expect(user.codex_auth_json).to include("codex-access-existing")
      expect(user.github_token).to eq("ghp_existing")
      expect(user.telegram_chat_id).to eq("123456")
    end

    it "clears each stored credential only through the explicit clear control" do
      User::CLEARABLE_CREDENTIALS.each_key do |credential|
        patch credentials_path, params: { clear_credential: credential }
        expect(response).to redirect_to(edit_credentials_path)
        expect(flash[:notice]).to include("cleared")
        expect(user.reload.public_send(credential)).to be_nil
      end
    end

    it "shows cleared credentials as not set after clearing" do
      patch credentials_path, params: { clear_credential: "github_token" }
      get edit_credentials_path

      expect(response.body).to include("GitHub token")
      expect(credentials_document.text).to include("Not set.")
    end

    it "rejects unknown clear credential names" do
      patch credentials_path, params: { clear_credential: "email_address" }

      expect(response).to redirect_to(edit_credentials_path)
      expect(flash[:alert]).to eq("Unknown credential.")
      expect(user.reload.email_address).to be_present
    end

    it "updates the agent provider" do
      patch credentials_path, params: { user: { agent_provider: "codex" } }
      expect(response).to redirect_to(edit_credentials_path)
      expect(user.reload.agent_provider).to eq("codex")
    end

    it "updates Codex auth mode and auth.json" do
      auth_json = Factories.codex_auth_json(access_token: "new-access")
      patch credentials_path, params: { user: { codex_auth_mode: "chatgpt_login", codex_auth_json: auth_json } }
      expect(response).to redirect_to(edit_credentials_path)
      user.reload
      expect(user.codex_auth_mode).to eq("chatgpt_login")
      expect(user.codex_auth_json).to eq(auth_json)
    end

    it "updates agent_max_turns when provided" do
      patch credentials_path, params: { user: { agent_max_turns: "500" } }
      expect(response).to redirect_to(edit_credentials_path)
      expect(user.reload.agent_max_turns).to eq(500)
    end

    it "updates telegram_chat_id when provided" do
      patch credentials_path, params: { user: { telegram_chat_id: " 123456 " } }
      expect(response).to redirect_to(edit_credentials_path)
      expect(user.reload.telegram_chat_id).to eq("123456")
    end

    it "updates the auto-approval fallback" do
      patch credentials_path, params: { user: { auto_approve_mode: "if_graders_pass" } }
      expect(response).to redirect_to(edit_credentials_path)
      expect(user.reload.auto_approve_mode).to eq("if_graders_pass")
    end

    it "rejects a non-numeric telegram_chat_id" do
      patch credentials_path, params: { user: { telegram_chat_id: "not-a-chat" } }
      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.telegram_chat_id).to eq("123456")
    end

    it "rejects an out-of-range agent_max_turns" do
      original = user.agent_max_turns
      patch credentials_path, params: { user: { agent_max_turns: "9999" } }
      expect(response).to have_http_status(:unprocessable_content)
      expect(user.reload.agent_max_turns).to eq(original)
    end

    it "leaves agent_max_turns unchanged when blank" do
      original = user.agent_max_turns
      patch credentials_path, params: { user: { agent_max_turns: "" } }
      expect(user.reload.agent_max_turns).to eq(original)
    end
  end

  describe "API token (admin only)" do
    context "as admin" do
      let(:admin) { Factories.user }
      before { sign_in_as(admin) }

      it "rotate_api_token issues a fresh token and shows it once via flash" do
        post rotate_api_token_credentials_path
        expect(response).to redirect_to(edit_credentials_path)
        get edit_credentials_path
        # Plaintext appears in the body once (the flash-reveal block)
        expect(response.body).to match(/syrus_[A-Za-z0-9_-]{30,}/)
        # Persisted (deterministic-encrypted) so we can re-look-up
        expect(admin.reload.api_token).to start_with("syrus_")
      end

      it "revoke_api_token clears the column" do
        admin.generate_api_token!
        delete revoke_api_token_credentials_path
        expect(response).to redirect_to(edit_credentials_path)
        expect(admin.reload.api_token).to be_nil
      end
    end

    context "as non-admin" do
      let(:admin) { Factories.user }       # first user → admin
      let(:non_admin) { admin; Factories.user }
      before { sign_in_as(non_admin) }

      it "blocks rotate_api_token" do
        post rotate_api_token_credentials_path
        expect(response).to redirect_to(edit_credentials_path)
        expect(flash[:alert]).to match(/admin/i)
        expect(non_admin.reload.api_token).to be_nil
      end

      it "blocks revoke_api_token" do
        non_admin  # eager-eval before stubbing
        delete revoke_api_token_credentials_path
        expect(flash[:alert]).to match(/admin/i)
      end
    end
  end
end
