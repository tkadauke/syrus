require "rails_helper"

RSpec.describe "API: /api/v1/app/client_metrics", type: :request do
  let(:user) { Factories.user }

  around do |example|
    original_registry = Syrus::Metrics.registry
    Syrus::Metrics.reset!
    ClientMetrics.declare_metrics!
    example.run
  ensure
    Syrus::Metrics.instance_variable_set(:@registry, original_registry)
  end

  def samples(metric)
    Syrus::Metrics.counter(metric).samples.to_h { |labels, value| [ labels[:resource], value ] }
  end

  it "401s when signed out" do
    post "/api/v1/app/client_metrics", params: { client_metrics: [ { name: "entity_patch_applications", resource: "job" } ] }

    expect(response).to have_http_status(:unauthorized)
  end

  it "records a batch of client-reported counters and responds 202" do
    sign_in_as(user)

    post "/api/v1/app/client_metrics", params: {
      client_metrics: [
        { name: "entity_patch_applications", resource: "job" },
        { name: "entity_patch_applications", resource: "job" },
        { name: "hidden_tab_suppressed_fetches", resource: "chat", by: 2 }
      ]
    }

    expect(response).to have_http_status(:accepted)
    expect(samples(:syrus_client_entity_patch_applications_total)).to eq("job" => 2)
    expect(samples(:syrus_client_hidden_tab_suppressed_fetches_total)).to eq("chat" => 2)
  end

  it "does not 500 on a malformed entry, just skips what it cannot record" do
    sign_in_as(user)

    post "/api/v1/app/client_metrics", params: { client_metrics: [ { name: "totally-unknown" } ] }

    expect(response).to have_http_status(:accepted)
  end
end
