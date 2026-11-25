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
      mode: "availability_failover",
      automatic: true,
      original_provider: "codex",
      selected_provider: "claude",
      reason: "provider_unavailable"
    )
  end

  it "presents a healthy matched-rule selection as policy routing with its evidence" do
    job = Factories.job
    workflow = job.workflows.last
    workflow.update!(agent_provider: "claude", artifacts: {
      "agent_provider_routing_decision" => {
        "original_provider" => "codex", "selected_provider" => "claude",
        "decision_mode" => "policy_routing", "automatic_failover" => false,
        "availability_state" => "available", "candidate_availability_state" => "available",
        "decided_at" => "2026-11-25T10:00:00Z",
        "routing_resolution" => {
          "source_scope" => "user", "matched_rule" => { "id" => 7, "position" => 2, "conditions" => { "usage" => {} } },
          "condition_results" => { "matched" => true, "conditions" => { "usage" => { "actual" => { "remaining_percent" => 22 } } } }
        }
      }
    })

    payload = described_class.for_workflow(workflow, configured_provider: "codex")

    expect(payload).to include(mode: "policy_routing", automatic: false, decided_at: "2026-11-25T10:00:00Z")
    expect(payload[:routing]).to include(matched_rule_id: 7, matched_rule_position: 2)
    expect(payload[:unavailable]).to be_nil
  end

  it "safely derives policy routing for a legacy artifact whose recorded providers are available" do
    job = Factories.job
    workflow = job.workflows.last
    workflow.update!(agent_provider: "claude", artifacts: {
      "provider_failover_decision" => {
        "original_provider" => "codex", "selected_provider" => "claude",
        "automatic_failover" => true, "availability_state" => "available",
        "unavailable" => { "provider" => "codex", "state" => "available" }
      }
    })

    payload = described_class.for_workflow(workflow, configured_provider: "codex")

    expect(payload).to include(mode: "policy_routing", automatic: false)
    expect(payload[:unavailable]).to be_nil
  end

  it "keeps an explicit workflow provider override distinct" do
    job = Factories.job
    workflow = job.workflows.last
    workflow.update!(agent_provider: "claude", artifacts: {})

    expect(described_class.for_workflow(workflow, configured_provider: "codex")).to include(
      mode: "operator", automatic: false, reason: "operator_selected_provider"
    )
  end
end
