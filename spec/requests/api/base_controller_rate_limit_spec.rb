require "rails_helper"

RSpec.describe "API: bearer token rate limiting", type: :request do
  let(:rate_limit_backend) { ActiveSupport::Cache::MemoryStore.new }

  before do
    # The controller captured the :null_store cache_store at class-load
    # time in the test env; delegate to a real per-example MemoryStore so
    # the counter is observable and resets deterministically between
    # examples. Same pattern as spec/requests/api/v1/app/auth_rate_limit_spec.rb.
    allow(Api::BaseController.cache_store)
      .to receive(:read) { |*args, **kwargs| rate_limit_backend.read(*args, **kwargs) }
    allow(Api::BaseController.cache_store)
      .to receive(:increment) { |*args, **kwargs| rate_limit_backend.increment(*args, **kwargs) }
  end

  def parse_body = JSON.parse(response.body)

  it "401s repeated bad bearer tokens without tripping the limiter" do
    5.times do
      get "/api/v1/admin/version", headers: { "Authorization" => "Bearer nonsense" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  it "429s after the bad-token limit is exceeded, keyed by source IP" do
    Api::BaseController::BAD_API_TOKEN_LIMIT.times do
      get "/api/v1/admin/version", headers: { "Authorization" => "Bearer nonsense" }
      expect(response).to have_http_status(:unauthorized)
    end

    get "/api/v1/admin/version", headers: { "Authorization" => "Bearer nonsense" }

    expect(response).to have_http_status(:too_many_requests)
    expect(parse_body.dig("error", "code")).to eq("rate_limited")
  end

  it "does not count a valid token toward the bad-token limit" do
    admin = Factories.user(admin: true)
    token = admin.generate_api_token!

    (Api::BaseController::BAD_API_TOKEN_LIMIT + 5).times do
      get "/api/v1/admin/version", headers: { "Authorization" => "Bearer #{token}" }
      expect(response).to be_successful
    end
  end
end
