require "rails_helper"

RSpec.describe "serial review panels" do
  let(:user) { Factories.user(claude_oauth_token: "test", codex_api_key: "test") }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job(repository: repository, user: user, owner_user: user) }
  let(:workflow) { job.workflows.last }
  let(:resolution) { instance_double(ProviderRouting::Resolver::PanelResolution, matched_rule: instance_double(ProviderRoutingRule, id: 44)) }
  let(:decision) do
    ProviderRouting::AvailabilitySelector::PanelDecision.new(
      members: members,
      available_members: members,
      unavailable_members: [],
      consensus: "majority",
      on_unavailable: "drop",
      min_members: 2,
      disposition: "proceed",
      routing_resolution: resolution
    )
  end
  let(:members) do
    [
      { "provider" => "claude", "model" => "sonnet", "effort_level" => "high", "available" => true },
      { "provider" => "codex", "model" => "gpt-5", "effort_level" => "medium", "available" => true }
    ]
  end

  before do
    allow(ProviderRouting::AvailabilitySelector).to receive(:panel).and_return(decision)
    allow(ProviderRouting::Resolver).to receive(:rule_configured?).and_return(true)
  end

  def panel_decision(available: members, unavailable: [], disposition: "proceed", min_members: 2, consensus: "majority")
    ProviderRouting::AvailabilitySelector::PanelDecision.new(
      members: available + unavailable,
      available_members: available,
      unavailable_members: unavailable,
      consensus: consensus,
      on_unavailable: disposition == "proceed" ? "drop" : disposition,
      min_members: min_members,
      disposition: disposition,
      routing_resolution: resolution
    )
  end

  it "pins member Runs while admitting the original review as a control step" do
    review = Step.create!(workflow: workflow, kind: "adversarial_review", position: 100, iteration: 1, loop_id: "review-loop")

    control_candidate = StepDispatcher.run_provider_candidate_for(review, workflow)
    expect(control_candidate.provider).to eq(workflow.agent_provider)
    expect(review.reload.details["panel_execution"]).to include("panel_id" => "routing-rule-44", "consensus" => "majority")

    member = Step.create!(workflow: workflow, kind: "adversarial_review", position: 101, iteration: 1, loop_id: "review-loop",
      details: { "panel_member" => true, "provider" => "codex", "model" => "gpt-5", "effort_level" => "medium" })
    member_candidate = StepDispatcher.run_provider_candidate_for(member, workflow)
    expect(member_candidate.to_h).to eq(provider: "codex", model: "gpt-5", effort_level: "medium")
  end

  it "uses the admission-time panel decision even if availability changes before execution" do
    review = Step.create!(workflow: workflow, kind: "adversarial_review", position: 100, iteration: 1, loop_id: "review-loop")
    StepDispatcher.run_provider_candidate_for(review, workflow)
    hold = panel_decision(available: [], unavailable: members, disposition: "hold")
    allow(ProviderRouting::AvailabilitySelector).to receive(:panel).and_return(hold)
    expect(StepDispatcher.run_provider_candidate_for(review, workflow).provider).to eq(workflow.agent_provider)
    handler = Steps::AdversarialReview.new(Run.create!(job: job, step: review, trigger_kind: workflow.trigger_kind))
    allow(handler).to receive(:review_config).and_return(nil)

    expect(handler.send(:materialize_review_panel!)).to be(true)
    expect(workflow.steps.where(loop_id: "review-loop").count { |step| step.details["panel_member"] }).to eq(2)
    expect(ProviderRouting::AvailabilitySelector).to have_received(:panel).once
  end

  it "holds at admission without creating a Run candidate" do
    hold = panel_decision(available: [], unavailable: members, disposition: "hold")
    allow(ProviderRouting::AvailabilitySelector).to receive(:panel).and_return(hold)
    allow(ProviderRouting::HoldAdmission).to receive(:apply!)
    review = Step.create!(workflow: workflow, kind: "adversarial_review", position: 100, iteration: 1, loop_id: "review-loop")

    expect(StepDispatcher.run_provider_candidate_for(review, workflow)).to be_nil
    expect(ProviderRouting::HoldAdmission).to have_received(:apply!).with(workflow: workflow, decision: hold, step: review)
  end

  it "pins a single-member panel to its admitted member without expanding the chain" do
    single = panel_decision(available: [ members.last ], min_members: 1)
    allow(ProviderRouting::AvailabilitySelector).to receive(:panel).and_return(single)
    review = Step.create!(workflow: workflow, kind: "adversarial_review", position: 100, iteration: 1, loop_id: "review-loop")

    expect(StepDispatcher.run_provider_candidate_for(review, workflow).to_h).to eq(
      provider: "codex", model: "gpt-5", effort_level: "medium"
    )
    allow(ProviderRouting::AvailabilitySelector).to receive(:panel).and_return(panel_decision(available: [], unavailable: members, disposition: "hold"))
    expect(StepDispatcher.run_provider_candidate_for(review, workflow).provider).to eq("codex")
    handler = Steps::AdversarialReview.new(Run.create!(job: job, step: review, trigger_kind: workflow.trigger_kind, agent_provider: "codex"))
    expect(handler.send(:materialize_review_panel!)).to be(false)
    expect(workflow.steps.where(loop_id: "review-loop")).to contain_exactly(review)
  end

  it "fails a panel whose unavailable-member policy is fail" do
    failed = panel_decision(available: [ members.first ], unavailable: [ members.last ], disposition: "fail")
    allow(ProviderRouting::AvailabilitySelector).to receive(:panel).and_return(failed)
    review = Step.create!(workflow: workflow, kind: "adversarial_review", position: 100, iteration: 1, loop_id: "review-loop")
    StepDispatcher.run_provider_candidate_for(review, workflow)
    handler = Steps::AdversarialReview.new(Run.create!(job: job, step: review, trigger_kind: workflow.trigger_kind))

    expect { handler.send(:materialize_review_panel!) }.to raise_error(Steps::Base::StepFailed, /policy is fail/)
  end

  [ false, true ].each do |required|
    it "records an undersized dropped panel as skipped when required is #{required}" do
      dropped = panel_decision(available: [ members.first ], unavailable: [ members.last ], disposition: "drop")
      allow(ProviderRouting::AvailabilitySelector).to receive(:panel).and_return(dropped)
      review = Step.create!(workflow: workflow, kind: "adversarial_review", position: 100, iteration: 1, loop_id: "review-loop")
      StepDispatcher.run_provider_candidate_for(review, workflow)
      handler = Steps::AdversarialReview.new(Run.create!(job: job, step: review, trigger_kind: workflow.trigger_kind))
      allow(handler).to receive(:review_config).and_return(instance_double(SyrusYml::AdversarialReviewConfig, required: required))
      handler.send(:materialize_review_panel!)
      collect = workflow.steps.find_by!(kind: "review_panel_collect", loop_id: "review-loop")
      collect_handler = Steps::ReviewPanelCollect.new(Run.create!(job: job, step: collect, trigger_kind: workflow.trigger_kind))

      if required
        expect { collect_handler.call }.to raise_error(Steps::Base::StepFailed, /minimum member count/)
      else
        expect { collect_handler.call }.not_to raise_error
      end
      expect(workflow.reload.artifact("adversarial_review_iterations").last).to include("aggregate" => true, "verdict" => "skipped")
    end
  end

  it "leaves a non-panel review step and chain unchanged" do
    allow(ProviderRouting::AvailabilitySelector).to receive(:panel).and_return(nil)
    review = Step.create!(workflow: workflow, kind: "adversarial_review", position: 100, iteration: 1, loop_id: "review-loop")
    handler = Steps::AdversarialReview.new(Run.create!(job: job, step: review, trigger_kind: workflow.trigger_kind))

    expect(handler.send(:materialize_review_panel!)).to be(false)
    expect(workflow.steps.where(loop_id: "review-loop")).to contain_exactly(review)
  end

  [ 1, 2, 3 ].each do |iteration|
    it "materializes pinned serial members and a collector for round #{iteration}" do
      review = Step.create!(workflow: workflow, kind: "adversarial_review", position: 100, iteration: iteration, loop_id: "review-loop")
      run = Run.create!(job: job, step: review, trigger_kind: workflow.trigger_kind)
      handler = Steps::AdversarialReview.new(run)
      allow(handler).to receive(:review_config).and_return(nil)
      StepDispatcher.run_provider_candidate_for(review, workflow)

      expect(handler.send(:materialize_review_panel!)).to be(true)

      steps = workflow.steps.where(loop_id: "review-loop", iteration: iteration).order(:position).to_a
      expect(steps.map(&:kind)).to eq(%w[adversarial_review adversarial_review adversarial_review review_panel_collect])
      expect(steps.drop(1).first(2).map { |step| step.details["provider"] }).to eq(%w[claude codex])
      expect(steps.each_cons(2).all? { |left, right| left.next_step_id == right.id }).to be(true)
      expect(steps.last.details).to include("panel_review_kind" => "adversarial_review", "consensus" => "majority")
    end
  end

  it "collects member votes as the final aggregate artifact" do
    collect = Step.create!(
      workflow: workflow, kind: "review_panel_collect", position: 100, iteration: 2, loop_id: "review-loop",
      details: { "panel_review_kind" => "security_review", "panel_id" => "routing-rule-44", "consensus" => "majority", "min_members" => 2, "dropped_members" => [] }
    )
    workflow.set_artifact!("security_review_iterations", [
      { "iteration" => 2, "panel_id" => "routing-rule-44", "provider" => "claude", "verdict" => "approved", "critique" => "Clean." },
      { "iteration" => 2, "panel_id" => "routing-rule-44", "provider" => "codex", "verdict" => "needs_work", "critique" => "Minor concern." },
      { "iteration" => 2, "panel_id" => "routing-rule-44", "provider" => "gemini", "verdict" => "approved", "critique" => "Clean." }
    ])

    Steps::ReviewPanelCollect.new(Run.create!(job: job, step: collect, trigger_kind: workflow.trigger_kind)).call

    aggregate = workflow.reload.artifact("security_review_iterations").last
    expect(aggregate).to include("aggregate" => true, "verdict" => "approved", "consensus" => "majority")
    expect(aggregate["vote_breakdown"]).to include("approved" => 2, "needs_work" => 1, "required_approvals" => 2, "total" => 3)
    expect(aggregate["non_blocking_findings"]).to contain_exactly(include("provider" => "codex", "critique" => "Minor concern."))
  end

  it "resumes only the same panel member's prior provider session" do
    prior_steps = %w[claude codex].map.with_index do |provider, index|
      step = Step.create!(workflow: workflow, kind: "adversarial_review", position: 100 + index, iteration: 1, loop_id: "review-loop",
        details: { "panel_member" => true, "panel_id" => "routing-rule-44", "provider" => provider })
      prior_run = Run.create!(job: job, step: step, trigger_kind: workflow.trigger_kind, state: "succeeded", agent_provider: provider)
      ProviderSession.create!(resumable: prior_run, session_id: "#{provider}-session", transcript_jsonl: "{}\n")
      step
    end
    current = Step.create!(workflow: workflow, kind: "adversarial_review", position: 102, iteration: 2, loop_id: "review-loop",
      details: { "panel_member" => true, "panel_id" => "routing-rule-44", "provider" => "codex" })
    handler = Steps::AdversarialReview.new(Run.create!(job: job, step: current, trigger_kind: workflow.trigger_kind, agent_provider: "codex"))

    expect(handler.send(:parent_session_id)).to eq("codex-session")
    expect(prior_steps.size).to eq(2)
  end

  it "does not feed minority findings from an approved panel to the repair agent" do
    workflow.set_artifact!("adversarial_review_iterations", [
      { "iteration" => 1, "panel_id" => "routing-rule-44", "provider" => "codex", "verdict" => "needs_work", "critique" => "Minor concern." },
      { "iteration" => 1, "panel_id" => "routing-rule-44", "aggregate" => true, "verdict" => "approved" }
    ])
    implement = workflow.steps.find_by!(kind: "implement")
    handler = Steps::Implement.new(Run.create!(job: job, step: implement, trigger_kind: workflow.trigger_kind))

    expect(handler.send(:needs_work_review_section, "adversarial_review_iterations", "Review feedback:")).to be_nil
  end
end
