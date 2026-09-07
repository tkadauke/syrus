require "rails_helper"

RSpec.describe App::AgentConversationPayload do
  let(:repository) { Factories.repository }
  let(:job) { Factories.job_record(repository: repository) }

  def create_workflow(trigger_kind: "initial", artifacts: {})
    Workflow.create!(
      job: job,
      user: job.user,
      trigger_kind: trigger_kind,
      agent_provider: "claude",
      artifacts: artifacts
    )
  end

  def create_step(workflow:, kind:, position:, iteration: 1, details: {}, state: "succeeded", depends_on_ids: [])
    Step.create!(
      workflow: workflow,
      kind: kind,
      position: position,
      iteration: iteration,
      details: details,
      state: state,
      depends_on_ids: depends_on_ids
    )
  end

  def create_run(step:, agent_summary: nil, agent_provider: "claude", state: "succeeded")
    Run.create!(
      job: job,
      step: step,
      trigger_kind: step.workflow.trigger_kind,
      agent_provider: agent_provider,
      agent_summary: agent_summary,
      state: state,
      started_at: 10.minutes.ago,
      finished_at: 5.minutes.ago
    )
  end

  def node(payload, id) = payload[:nodes].find { |n| n[:id] == id }

  def edge?(payload, from_id, to_id)
    payload[:edges].any? { |e| e[:from_id] == from_id && e[:to_id] == to_id }
  end

  describe "a plain initial workflow with adversarial/visual review loops and a grader fanout" do
    it "builds agent_session and deterministic_check nodes wired through the loop and fan-out/fan-in" do
      workflow = create_workflow(trigger_kind: "initial")

      prepare = create_step(workflow: workflow, kind: "prepare", position: 0)
      implement1 = create_step(workflow: workflow, kind: "implement", position: 1)
      adv1 = create_step(workflow: workflow, kind: "adversarial_review", position: 2, iteration: 1)
      implement2 = create_step(workflow: workflow, kind: "implement", position: 3, iteration: 2)
      adv2 = create_step(workflow: workflow, kind: "adversarial_review", position: 4, iteration: 2)
      visual1 = create_step(workflow: workflow, kind: "visual_review", position: 5, iteration: 1)
      fanout = create_step(workflow: workflow, kind: "grader_fanout", position: 6)
      rspec = create_step(
        workflow: workflow, kind: "grader", position: 7,
        details: { "name" => "rspec", "command" => "bin/rspec", "exit_code" => 0, "output" => "1 example, 0 failures" },
        depends_on_ids: [ fanout.id ]
      )
      eslint = create_step(
        workflow: workflow, kind: "grader", position: 8,
        details: { "name" => "eslint", "command" => "eslint .", "exit_code" => 0, "output" => "0 problems" },
        depends_on_ids: [ fanout.id ]
      )
      collect = create_step(workflow: workflow, kind: "grader_collect", position: 9, depends_on_ids: [ rspec.id, eslint.id ])
      summarize = create_step(workflow: workflow, kind: "summarize", position: 10)

      [ [ prepare, implement1 ], [ implement1, adv1 ], [ adv1, implement2 ], [ implement2, adv2 ],
        [ adv2, visual1 ], [ visual1, fanout ], [ fanout, rspec ], [ rspec, eslint ], [ eslint, collect ],
        [ collect, summarize ] ].each { |a, b| a.update!(next_step_id: b.id) }

      workflow.set_artifact!("adversarial_review_iterations", [
        { "iteration" => 1, "verdict" => "needs_work", "critique" => "missing tests" },
        { "iteration" => 2, "verdict" => "approved", "critique" => "Looks good" }
      ])
      workflow.set_artifact!("visual_review_iterations", [
        { "iteration" => 1, "verdict" => "approved", "critique" => "Renders fine" }
      ])

      run_implement1 = create_run(step: implement1, agent_summary: "Added feature")
      run_adv1 = create_run(step: adv1)
      run_implement2 = create_run(step: implement2, agent_summary: "Added tests")
      run_adv2 = create_run(step: adv2)
      run_visual1 = create_run(step: visual1)
      run_summarize = create_run(step: summarize, agent_summary: "Implemented the feature end to end")

      payload = described_class.build(job: job)

      implement1_id = "agent_session-#{run_implement1.id}"
      adv1_id = "agent_session-#{run_adv1.id}"
      implement2_id = "agent_session-#{run_implement2.id}"
      adv2_id = "agent_session-#{run_adv2.id}"
      visual1_id = "agent_session-#{run_visual1.id}"
      rspec_id = "deterministic_check-#{rspec.id}"
      eslint_id = "deterministic_check-#{eslint.id}"
      summarize_id = "agent_session-#{run_summarize.id}"

      # prepare/grader_fanout/grader_collect never become nodes.
      node_ids = payload[:nodes].map { |n| n[:id] }
      expect(node_ids).to contain_exactly(
        implement1_id, adv1_id, implement2_id, adv2_id, visual1_id, rspec_id, eslint_id, summarize_id
      )

      # Loop chain, including the repair round.
      expect(edge?(payload, implement1_id, adv1_id)).to be true
      expect(edge?(payload, adv1_id, implement2_id)).to be true
      expect(edge?(payload, implement2_id, adv2_id)).to be true
      expect(edge?(payload, adv2_id, visual1_id)).to be true

      # Fan-out from visual review into both parallel graders (through the
      # non-node grader_fanout step).
      expect(edge?(payload, visual1_id, rspec_id)).to be true
      expect(edge?(payload, visual1_id, eslint_id)).to be true

      # Fan-in: both graders converge on summarize (through the non-node
      # grader_collect step) instead of grader_collect being its own node.
      expect(edge?(payload, rspec_id, summarize_id)).to be true
      expect(edge?(payload, eslint_id, summarize_id)).to be true

      expect(node(payload, adv1_id)).to include(role: AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER, summary: "missing tests")
      expect(node(payload, adv1_id)[:detail]).to include("verdict" => "needs_work")
      expect(node(payload, adv2_id)).to include(summary: "Looks good")
      expect(node(payload, adv2_id)[:detail]).to include("verdict" => "approved")
      expect(node(payload, visual1_id)).to include(role: AgentRole::WORKFLOW_VISUAL_REVIEWER, summary: "Renders fine")
      expect(node(payload, implement1_id)).to include(role: AgentRole::WORKFLOW_IMPLEMENT, summary: "Added feature", agentic: true)
      expect(node(payload, summarize_id)).to include(summary: "Implemented the feature end to end")

      expect(node(payload, rspec_id)).to include(
        kind: "deterministic_check", agentic: false, label: "rspec", state: "succeeded", summary: "rspec passed"
      )
      expect(node(payload, rspec_id)[:detail]).to include("command" => "bin/rspec")
      expect(node(payload, eslint_id)).to include(label: "eslint")

      expect(payload[:nodes].none? { |n| n[:kind] == "external_trigger" }).to be true
    end
  end

  describe "a pr_comment follow-up Workflow" do
    it "adds an external_trigger node sourced from the stashed PR comments, wired from the prior workflow" do
      initial = create_workflow(trigger_kind: "initial")
      initial_implement = create_step(workflow: initial, kind: "implement", position: 0)
      run_initial = create_run(step: initial_implement, agent_summary: "Initial implementation")

      follow_up = create_workflow(
        trigger_kind: "pr_comment",
        artifacts: {
          "pr_comments" => [
            { "author" => "alice", "body" => "Please rename this method.", "created_at" => 10.minutes.ago.iso8601 }
          ],
          "feedback_cutoff" => 1.hour.ago.iso8601,
          "pr_feedback_source_handle" => "alice"
        }
      )
      respond_step = create_step(workflow: follow_up, kind: "respond", position: 0)
      push_step = create_step(workflow: follow_up, kind: "push", position: 1)
      respond_step.update!(next_step_id: push_step.id)
      run_respond = create_run(step: respond_step, agent_summary: "Renamed the method")

      payload = described_class.build(job: job)

      trigger_node = payload[:nodes].find { |n| n[:kind] == "external_trigger" }
      expect(trigger_node).to include(
        kind: "external_trigger",
        workflow_id: follow_up.id,
        trigger_kind: "pr_comment",
        label: Workflow::TriggerKind.label_for("pr_comment"),
        summary: "PR comment from @alice"
      )
      expect(trigger_node[:detail]["source_handle"]).to eq("alice")
      expect(trigger_node[:detail]["comments"]).to be_present

      initial_node_id = "agent_session-#{run_initial.id}"
      respond_node_id = "agent_session-#{run_respond.id}"

      expect(edge?(payload, initial_node_id, trigger_node[:id])).to be true
      expect(edge?(payload, trigger_node[:id], respond_node_id)).to be true
    end
  end

  describe "a ci_failure retry Workflow" do
    it "adds an external_trigger node sourced from the stashed failing checks" do
      initial = create_workflow(trigger_kind: "initial")
      initial_implement = create_step(workflow: initial, kind: "implement", position: 0)
      run_initial = create_run(step: initial_implement, agent_summary: "Initial implementation")

      repair = create_workflow(
        trigger_kind: "ci_failure",
        artifacts: {
          "head_sha" => "abc1234",
          "base_sha" => "def5678",
          "failed_checks" => [ { "name" => "rspec", "conclusion" => "failure" } ]
        }
      )
      fix_step = create_step(workflow: repair, kind: "analyze_and_fix", position: 0)
      run_fix = create_run(step: fix_step, agent_summary: "Fixed the failing spec")

      payload = described_class.build(job: job)

      trigger_node = payload[:nodes].find { |n| n[:kind] == "external_trigger" }
      expect(trigger_node).to include(
        workflow_id: repair.id,
        trigger_kind: "ci_failure",
        summary: "CI failure: rspec"
      )
      expect(trigger_node[:detail]).to include("head_sha" => "abc1234", "base_sha" => "def5678")

      initial_node_id = "agent_session-#{run_initial.id}"
      fix_node_id = "agent_session-#{run_fix.id}"

      expect(edge?(payload, initial_node_id, trigger_node[:id])).to be true
      expect(edge?(payload, trigger_node[:id], fix_node_id)).to be true
    end
  end
end
