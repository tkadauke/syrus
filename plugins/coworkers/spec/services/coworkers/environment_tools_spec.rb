require "rails_helper"

RSpec.describe Coworkers::EnvironmentTools do
  let(:owner) { Factories.user }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Toolsmith", handle: "environment-toolsmith",
                                workspace_repo: "https://github.com/acme/widgets.git")
  end
  let!(:environment) { Coworkers::Environment.create!(coworker:, state: "draft") }
  let(:tool_context) { instance_double(Syrus::Host::ToolContext, user: owner, agent_actor: coworker, role: AgentRole::COWORKER_CHAT) }

  before do
    Feature.create!(slug: "coworker_custom_environments", category: "Labs", name: "x", enabled: true, experimental: true)
    allow(AppSetting).to receive(:beta_mode_enabled?).and_return(true)
    allow(Syrus::Host::ToolContext).to receive(:from_server_context).and_return(tool_context)
    allow(Syrus::Host::RuntimeImages).to receive(:active_base).and_return(nil)
  end

  it "returns the safe inspection contract" do
    response = Coworkers::EnvironmentTools::Inspect.call(server_context: {})
    payload = JSON.parse(response.content.first[:text])

    expect(payload.fetch("environment")).to include("v" => 1, "environment_id" => environment.id,
                                                     "state" => "draft", "error_code" => nil)
  end

  it "returns an actionable structured error when the live gate is disabled" do
    Feature.find_by!(slug: "coworker_custom_environments").update!(enabled: false)

    response = Coworkers::EnvironmentTools::Inspect.call(server_context: {})
    payload = JSON.parse(response.content.first[:text])

    expect(response).to be_error
    expect(payload.fetch("error")).to include(
      "code" => "feature_disabled", "retryable" => false,
      "next_action" => "Ask an administrator to enable coworker custom environments."
    )
  end
end
