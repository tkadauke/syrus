require "rails_helper"

RSpec.describe App::ProviderFailoverPayload do
  it "describes provider routing at workflow creation as automatic rather than operator-selected" do
    job = Factories.job
    workflow = job.workflows.last
    workflow.update!(
      agent_provider: "claude",
      artifacts: workflow.artifacts.to_h.merge(
        "agent_provider_routing_decision" => {
          "original_provider" => "codex",
          "selected_provider" => "claude",
          "automatic_failover" => true,
          "manual_override" => false,
          "reason" => "provider_unavailable"
        }
      )
    )

    expect(described_class.for_workflow(workflow, configured_provider: "codex")).to include(
      mode: "automatic",
      automatic: true,
      original_provider: "codex",
      selected_provider: "claude",
      reason: "provider_unavailable"
    )
  end
end
