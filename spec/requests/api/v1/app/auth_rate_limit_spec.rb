require "rails_helper"

RSpec.describe "API: /api/v1/app/auth rate limiting", type: :request do
  let(:rate_limit_backend) { ActiveSupport::Cache::MemoryStore.new }

  before do
    # `rate_limit` captured the controller's cache store when the class
    # loaded; in the test env that's the :null_store, whose #increment
    # returns nil so the limiter never sees a count. Delegate #increment to
    # a real per-example MemoryStore so the limit is observable and the
    # counter resets deterministically between examples.
    allow(Api::V1::App::AuthController.cache_store)
      .to receive(:increment) { |*args, **kwargs| rate_limit_backend.increment(*args, **kwargs) }
  end

  def parse_body = JSON.parse(response.body)

  it "returns 429 rate_limited on the 11th JSON sign-in attempt within the window" do
    Factories.user(email_address: "operator@example.com", password: "supersecret")

    10.times do
      post "/api/v1/app/auth/session", params: {
        email_address: "operator@example.com",
        password: "wrong"
      }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    post "/api/v1/app/auth/session", params: {
      email_address: "operator@example.com",
      password: "supersecret"
    }, as: :json

    expect(response).to have_http_status(:too_many_requests)
    expect(parse_body.dig("error", "code")).to eq("rate_limited")
    expect(parse_body.dig("error", "message")).to eq("Try again later.")
  end

  it "rate limits the JSON password-reset request endpoint" do
    Factories.user(email_address: "operator@example.com")

    10.times do
      post "/api/v1/app/auth/passwords", params: { email_address: "operator@example.com" }, as: :json
      expect(response).to have_http_status(:ok)
    end

    post "/api/v1/app/auth/passwords", params: { email_address: "operator@example.com" }, as: :json

    expect(response).to have_http_status(:too_many_requests)
    expect(parse_body.dig("error", "code")).to eq("rate_limited")
  end

  # Every E2E spec signs in from one address, far more than ten times, so the
  # limit throttled the suite itself: the first handful passed and the rest
  # failed waiting for the sign-in page to navigate.
  it "lifts the limit while SYRUS_DISABLE_AUTH_RATE_LIMIT is set" do
    Factories.user(email_address: "operator@example.com", password: "supersecret")
    ENV[AuthRateLimit::DISABLE_ENV_VAR] = "1"

    11.times do
      post "/api/v1/app/auth/session", params: {
        email_address: "operator@example.com",
        password: "wrong"
      }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end
  ensure
    ENV.delete(AuthRateLimit::DISABLE_ENV_VAR)
  end

  it "does not rate limit unrelated auth endpoints like signup state" do
    11.times { get "/api/v1/app/auth/signup" }

    expect(response).to have_http_status(:ok)
  end
end
