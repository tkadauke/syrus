require "rails_helper"

RSpec.describe "API: /api/v1/admin/runtime_image_build_network_rules", type: :request do
  let!(:admin) { Factories.user }
  let!(:admin_token) { admin.generate_api_token! }
  let(:non_admin_token) { Factories.user.generate_api_token! }
  def auth = { "Authorization" => "Bearer #{admin_token}" }
  let(:path) { "/api/v1/admin/runtime_image_build_network_rules" }

  it "lists rules with the source class catalogue" do
    RuntimeImageBuildNetworkRule.create!(source_class: "source_host", host: "github.com")
    get path, headers: auth
    body = JSON.parse(response.body)
    expect(response).to have_http_status(:ok)
    expect(body["rules"].map { |r| r["host"] }).to eq([ "github.com" ])
    expect(body["source_classes"].map { |c| c["key"] }).to match_array(RuntimeImages::BuildNetwork::SourceClass.keys)
    expect(body["source_classes"].find { |c| c["key"] == "internal_mirror" }).to include("allows_private_addresses" => true, "requirable" => true)
  end

  it "creates, updates, and deletes a rule, attributing the actor" do
    post path, params: { source_class: "language_registry", host: "PyPI.org", ecosystem: "pypi" }, headers: auth
    expect(response).to have_http_status(:created)
    created = JSON.parse(response.body)
    expect(created).to include("host" => "pypi.org", "port" => 443, "enabled" => true, "actor" => "user:#{admin.id}")

    patch "#{path}/#{created['id']}", params: { enabled: false }, headers: auth
    expect(JSON.parse(response.body)["enabled"]).to be(false)
    expect(RuntimeImages::BuildNetwork::Policy.current).to be_empty

    delete "#{path}/#{created['id']}", headers: auth
    expect(response).to have_http_status(:no_content)
    expect(RuntimeImageBuildNetworkRule.count).to eq(0)
  end

  it "rejects invalid rules with a machine-readable code" do
    post path, params: { source_class: "exact_domain", host: "169.254.169.254" }, headers: auth
    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body).dig("error", "code") || JSON.parse(response.body)["code"]).to eq("validation_failed")
  end

  it "401s without a token and 403s for non-admins" do
    get path
    expect(response).to have_http_status(:unauthorized)
    post path, params: { source_class: "source_host", host: "github.com" }, headers: { "Authorization" => "Bearer #{non_admin_token}" }
    expect(response).to have_http_status(:forbidden)
    expect(RuntimeImageBuildNetworkRule.count).to eq(0)
  end
end
