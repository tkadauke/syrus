require "rails_helper"

RSpec.describe "API: repository throughput metrics", type: :request do
  let(:snapshot_cache) { ActiveSupport::Cache::MemoryStore.new }

  before { allow(Rails).to receive(:cache).and_return(snapshot_cache) }

  it "serves metrics for a repository the user can access" do
    user = Factories.user
    repository = Factories.repository(user: user)
    sign_in_as(user)

    get "/api/v1/app/repositories/#{repository.id}/throughput_metrics"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["repository_id"]).to eq(repository.id)
    expect(response.parsed_body["version"]).to eq(Throughput::MetricContract::VERSION)
    expect(response.parsed_body["cache_status"]).to eq("computed")
    expect(response.parsed_body["repository"]).to include("id" => repository.id, "slug" => repository.slug)
    expect(response.parsed_body["tabs"].map { |tab| tab["key"] }).to include("throughput.repository")
  end

  it "serves a warm snapshot without invoking the metric contract" do
    user = Factories.user
    repository = Factories.repository(user: user)
    payload = { version: Throughput::MetricContract::VERSION, repository_id: repository.id,
                generated_at: Time.current.iso8601, windows: {} }
    snapshot_cache.write(Throughput::RepositorySnapshot.snapshot_key(repository.id), payload)
    expect(Throughput::MetricContract).not_to receive(:new)
    sign_in_as(user)

    get "/api/v1/app/repositories/#{repository.id}/throughput_metrics"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["cache_status"]).to eq("fresh")
  end

  it "returns an explicit unavailable response when a cold computation is already in progress" do
    user = Factories.user
    repository = Factories.repository(user: user)
    key = Throughput::RepositorySnapshot.snapshot_key(repository.id)
    snapshot_cache.write("#{key}:refreshing", true)
    sign_in_as(user)

    get "/api/v1/app/repositories/#{repository.id}/throughput_metrics"

    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body["error"]).to eq("throughput_snapshot_unavailable")
  end

  it "scopes lookup to repositories the signed-in user can access" do
    Factories.user(admin: true)
    other = Factories.repository(user: Factories.user)
    viewer = Factories.user
    sign_in_as(viewer)

    expect(Repository.accessible_to(viewer)).not_to include(other)
  end
end
