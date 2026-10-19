require "rails_helper"

RSpec.describe ProviderRouting::HoldReevaluator do
  let(:job) { Factories.job(job_provider_setting: "default") }

  before do
    allow(RepoGradeLoopPlan).to receive(:for_job).and_return(
      RepoGradeLoopPlan::Result.new(format_configured: false, generate_configured: false, graders_configured: false, source: nil, note: nil)
    )
    allow(RepoVisualReviewPlan).to receive(:for_job).and_return(
      RepoVisualReviewPlan::Result.new(enabled: false, rounds: 1, source: "none", note: nil)
    )
    allow(App::ProviderAvailability).to receive(:for_user).and_return(nil)
    allow(AgentProviders.for("claude")).to receive(:available_models).and_return([])
  end

  it "persists evidence and schedules timed holds without creating a Run" do
    wake_at = 1.hour.from_now.change(usec: 0)
    rule = ProviderRoutingRule.create!(
      scope_type: "repository", scope_id: job.repository_id, task_key: "initial", candidates: [],
      action: { type: "hold", reason: "Maintenance", resumption: { mode: "until_time", at: wake_at.iso8601 } }
    )

    expect {
      @workflow = Workflows::Initial.instantiate(job: job)
    }.to have_enqueued_job(WorkflowPhaseAdmissionJob).at(wake_at)

    hold = @workflow.provider_routing_holds.active.sole
    expect(hold).to have_attributes(provider_routing_rule: rule, resumption_mode: "until_time", next_reevaluation_at: wake_at)
    expect(hold.condition_evidence).to include("matched" => true)
    expect(hold.matched_scope).to include("source_scope" => "repository")
    expect(@workflow.runs).to be_empty
  end

  it "restarts ordered resolution after a timed hold wakes and selects the next rule" do
    first = ProviderRoutingRule.create!(
      scope_type: "repository", scope_id: job.repository_id, position: 1, task_key: "initial", candidates: [],
      action: { type: "hold", resumption: { mode: "until_time", at: 1.minute.ago.iso8601 } }
    )
    second = ProviderRoutingRule.create!(
      scope_type: "repository", scope_id: job.repository_id, position: 2, task_key: "initial",
      candidates: [ { provider: "claude" } ]
    )
    workflow = Workflows::Initial.instantiate(job: job)

    expect(described_class.call(workflow: workflow, step: workflow.first_step)).to be(true)
    expect(workflow.provider_routing_holds.active).to be_empty
    expect(workflow.provider_routing_holds.sole).to have_attributes(status: "cleared", release_kind: "time_elapsed", provider_routing_rule: first)
    expect(workflow.reload.artifact("agent_provider_routing_decision").dig("routing_resolution", "matched_rule", "id")).to eq(second.id)
  end

  it "clears a conditions hold after provider usage recovers" do
    availability = { usage: { remaining_percent: 5.0, observed_at: Time.current.iso8601 } }
    allow(App::ProviderAvailability).to receive(:for_user) { availability }
    ProviderRoutingRule.create!(
      scope_type: "repository", scope_id: job.repository_id, position: 1, task_key: "initial", candidates: [],
      conditions: { usage: { provider: "claude", remaining_percent_less_than: 10 } },
      action: { type: "hold", resumption: { mode: "when_conditions_clear" } }
    )
    ProviderRoutingRule.create!(
      scope_type: "repository", scope_id: job.repository_id, position: 2, task_key: "initial",
      candidates: [ { provider: "claude" } ]
    )
    workflow = Workflows::Initial.instantiate(job: job)
    expect(workflow.provider_routing_holds.active.sole.condition_evidence.dig("conditions", "usage", "actual", "remaining_percent")).to eq(5.0)

    availability = { usage: { remaining_percent: 50.0, observed_at: Time.current.iso8601 } }

    expect(described_class.call(workflow: workflow, step: workflow.first_step)).to be(true)
    expect(workflow.provider_routing_holds.active).to be_empty
    expect(workflow.reload.artifact("agent_provider_routing_decision").dig("routing_resolution", "matched_rule", "position")).to eq(2)
  end
  it "releases once under concurrent operator requests and records the actor and reason" do
    rule = ProviderRoutingRule.create!(
      scope_type: "repository", scope_id: job.repository_id, task_key: "initial", candidates: [],
      action: { type: "hold", reason: "Approval required", resumption: { mode: "manual" } }
    )
    workflow = Workflows::Initial.instantiate(job: job)
    hold = workflow.provider_routing_holds.active.sole

    expect {
      ProviderRouting::HoldRelease.call(hold: hold, user: job.user, reason: "Approved")
    }.to have_enqueued_job(WorkflowPhaseAdmissionJob).once

    expect(hold.reload).to have_attributes(status: "released", released_by_user: job.user, release_reason: "Approved", release_kind: "manual")
    expect(workflow.reload.artifact("released_provider_routing_hold_rule_ids")).to include(rule.id)
  end

  it "finishes the wake when release is retried after enqueue failure" do
    rule = ProviderRoutingRule.create!(
      scope_type: "repository", scope_id: job.repository_id, task_key: "initial", candidates: [],
      action: { type: "hold", resumption: { mode: "manual" } }
    )
    workflow = Workflows::Initial.instantiate(job: job)
    hold = workflow.provider_routing_holds.active.sole
    allow(WorkflowPhaseAdmissionJob).to receive(:enqueue_once).and_raise("queue unavailable")

    expect {
      ProviderRouting::HoldRelease.call(hold: hold, user: job.user, reason: "Approved")
    }.to raise_error("queue unavailable")
    expect(hold.reload).to have_attributes(status: "released", release_reason: "Approved")
    expect(workflow.reload.artifact("released_provider_routing_hold_rule_ids")).to include(rule.id)

    allow(WorkflowPhaseAdmissionJob).to receive(:enqueue_once).and_return(true)
    ProviderRouting::HoldRelease.call(hold: hold, user: job.user, reason: "Approved")

    expect(WorkflowPhaseAdmissionJob).to have_received(:enqueue_once).with(workflow.id, nil, force: true).twice
  end
end
