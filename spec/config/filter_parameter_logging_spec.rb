require "rails_helper"

RSpec.describe "parameter log filtering" do
  it "filters credential-bearing request parameters" do
    parameters = {
      "user" => { "codex_auth_json" => "codex-auth" },
      "credential" => { "payload" => "private-key" },
      "kubernetes_cluster" => { "kubeconfig" => "cluster-credentials" },
      "authorization" => "Bearer request-token",
      "code" => "oauth-code"
    }

    filtered = ActiveSupport::ParameterFilter
      .new(Rails.application.config.filter_parameters)
      .filter(parameters)

    expect(filtered).to eq(
      "user" => { "codex_auth_json" => "[FILTERED]" },
      "credential" => { "payload" => "[FILTERED]" },
      "kubernetes_cluster" => { "kubeconfig" => "[FILTERED]" },
      "authorization" => "[FILTERED]",
      "code" => "[FILTERED]"
    )
  end
end
