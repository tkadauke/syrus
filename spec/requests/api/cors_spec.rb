require "rails_helper"

RSpec.describe "API: CORS policy", type: :request do
  it "does not grant a cross-origin browser page access to API responses" do
    get "/api/v1/admin/version", headers: { "Origin" => "https://evil.example" }

    expect(response.headers["Access-Control-Allow-Origin"]).to be_nil
  end

  it "does not grant access even for a CORS preflight request" do
    options "/api/v1/admin/version", headers: {
      "Origin" => "https://evil.example",
      "Access-Control-Request-Method" => "GET"
    }

    expect(response.headers["Access-Control-Allow-Origin"]).to be_nil
  end
end
