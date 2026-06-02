require "rails_helper"

RSpec.describe "API: /api/v1/app/bootstrap", type: :request do
  def parse_body
    JSON.parse(response.body)
  end

  def with_env(vars)
    old_values = vars.keys.to_h { |key| [ key, ENV[key] ] }
    vars.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  it "returns a JSON 401 instead of redirecting when signed out" do
    get api_v1_app_bootstrap_path

    expect(response).to have_http_status(:unauthorized)
    expect(response.media_type).to eq("application/json")
    expect(parse_body).to eq(
      "error" => {
        "code" => "unauthorized",
        "message" => "Sign in to use the app API."
      }
    )
  end

  it "returns the signed-in user's browser bootstrap payload" do
    user = Factories.user(
      email_address: "operator@example.com",
      name: "Operator",
      scheduling_paused: true,
      landing_paused: true,
      agent_provider: "codex",
      agent_max_turns: 123
    )
    sign_in_as(user)

    get api_v1_app_bootstrap_path

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/json")

    body = parse_body
    expect(body["current_user"]).to include(
      "id" => user.id,
      "email_address" => "operator@example.com",
      "name" => "Operator",
      "display_name" => "Operator",
      "admin" => true,
      "scheduling_paused" => true,
      "landing_paused" => true,
      "agent_provider" => "codex",
      "agent_max_turns" => 123
    )
    expect(body["app"]).to include(
      "revision" => "dev",
      "revision_url" => nil
    )
    expect(body["navigation"]).to include(
      "default_chat_path" => new_chat_path
    )
    expect(body.dig("setup", "next_step")).to eq("credentials")
    expect(body.dig("setup", "paths", "setup_path")).to eq(setup_path)
    expect(body["csrf_token"]).to be_present
    expect(body["feature_flags"]).to eq("migrated_routes" => [])
  end

  it "uses the configured GitHub repository for non-dev revision links" do
    user = Factories.user
    sign_in_as(user)

    with_env("GIT_SHA" => "9c0f8d15", "SYRUS_GITHUB_REPO" => "operator/syrus") do
      get api_v1_app_bootstrap_path
    end

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("app", "revision_url")).to eq("https://github.com/operator/syrus/commit/9c0f8d15")
  end

  it "points the default chat navigation at the user's latest chat" do
    user = Factories.user
    old_chat = ChatSession.create!(user: user, last_message_at: 2.days.ago)
    latest_chat = ChatSession.create!(user: user, last_message_at: 1.hour.ago)
    sign_in_as(user)

    get api_v1_app_bootstrap_path

    expect(parse_body.dig("navigation", "default_chat_path")).to eq(chat_path(latest_chat))
    expect(parse_body.dig("navigation", "default_chat_path")).not_to eq(chat_path(old_chat))
  end
end
