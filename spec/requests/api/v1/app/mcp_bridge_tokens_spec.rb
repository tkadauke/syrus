require "rails_helper"

RSpec.describe "API: /api/v1/app/mcp_bridge_tokens", type: :request do
  let!(:_bootstrap_admin) { Factories.user(admin: true) }
  let(:user) { Factories.user }

  def body = JSON.parse(response.body)

  it "requires a signed-in user" do
    get "/api/v1/app/mcp_bridge_tokens"

    expect(response).to have_http_status(:unauthorized)
  end

  it "issues a token whose plaintext appears only in the create response" do
    sign_in_as(user)

    post "/api/v1/app/mcp_bridge_tokens", params: { name: "laptop" }

    expect(response).to have_http_status(:created)
    plaintext = body["plaintext"]
    expect(plaintext).to start_with(McpBridgeToken::TOKEN_PREFIX)
    expect(body["endpoint"]).to end_with("/mcp/bridge")
    expect(McpBridgeToken.authenticate(plaintext)&.user).to eq(user)
    expect(McpBridgeToken.last.token_digest).not_to include(plaintext)

    get "/api/v1/app/mcp_bridge_tokens"

    expect(body["tokens"].map { |token| token["name"] }).to eq([ "laptop" ])
    expect(response.body).not_to include(plaintext)
  end

  it "refuses a nameless token" do
    sign_in_as(user)

    post "/api/v1/app/mcp_bridge_tokens", params: { name: " " }

    expect(response).to have_http_status(:unprocessable_content)
    expect(body.dig("error", "code")).to eq("invalid_name")
  end

  it "revokes only the user's own tokens" do
    token, plaintext = McpBridgeToken.issue!(user:, name: "laptop")
    other, = McpBridgeToken.issue!(user: Factories.user, name: "theirs")
    sign_in_as(user)

    delete "/api/v1/app/mcp_bridge_tokens/#{token.id}"

    expect(response).to have_http_status(:ok)
    expect(McpBridgeToken.authenticate(plaintext)).to be_nil

    delete "/api/v1/app/mcp_bridge_tokens/#{other.id}"

    expect(response).to have_http_status(:not_found)
    expect(other.reload).to be_active
  end
end
