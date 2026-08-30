require "rails_helper"

RSpec.describe Workflows::LocalModeHandoff do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat) { ChatSession.create!(user: user, mode: "coding") }

  describe ".steps_for" do
    context "when job has no PR yet" do
      let(:job) { Factories.job_record(user: user, repository: repository, state: "running") }

      it "includes prepare, grader retry loop, summarize, test_plan, pr_open" do
        kinds = described_class.steps_for(job)
        expect(kinds.first).to eq("prepare")
        expect(kinds[1]).to be_a(Workflows::RetryUntil)
        expect(kinds[1].repair_steps).to eq(%w[ local_mode_handoff_fix ])
        expect(kinds[1].check_steps).to eq(%w[ grader_fanout grader_collect ])
        expect(kinds[1].repair_first).to be(false)
        expect(kinds.last(4)).to eq(%w[ summarize test_plan pr_open review_plan ])
      end

      it "materializes the new-PR chain template" do
        allow(AppSetting).to receive(:grade_max_iterations).and_return(5)
        workflow = described_class.instantiate(job: job)

        expect(workflow.steps.order(:position).pluck(:kind)).to eq(
          %w[ prepare grader_fanout grader_collect summarize test_plan pr_open review_plan ]
        )
        expect(workflow.chain_template).to eq([
          { "type" => "step", "kind" => "prepare" },
          { "type" => "retry_until", "max_iterations" => 5, "repair_first" => false,
            "repair" => [ "local_mode_handoff_fix" ], "check" => [ "grader_fanout", "grader_collect" ] },
          { "type" => "step", "kind" => "summarize" },
          { "type" => "step", "kind" => "test_plan" },
          { "type" => "step", "kind" => "pr_open" },
          { "type" => "step", "kind" => "review_plan" }
        ])
      end

      it "omits prepare when job has skip_prepare_reason" do
        allow(job).to receive(:skip_prepare?).and_return(true)
        kinds = described_class.steps_for(job)
        expect(kinds).not_to include("prepare")
        expect(kinds.first).to be_a(Workflows::RetryUntil)
        expect(kinds.last).to eq("review_plan")
      end
    end

    context "when job already has a PR" do
      let(:job) { Factories.job_record(user: user, repository: repository, state: "implemented", pr_number: 42) }

      it "includes prepare, grader retry loop, summarize_amend and push chain" do
        kinds = described_class.steps_for(job)
        expect(kinds.first).to eq("prepare")
        expect(kinds[1]).to be_a(Workflows::RetryUntil)
        expect(kinds[1].repair_steps).to eq(%w[ local_mode_handoff_fix ])
        expect(kinds[1].check_steps).to eq(%w[ grader_fanout grader_collect ])
        expect(kinds[1].repair_first).to be(false)
        expect(kinds).to include("summarize_amend")
        expect(kinds).not_to include("pr_open")
      end

      it "materializes the existing-PR chain template with push recovery" do
        allow(AppSetting).to receive(:grade_max_iterations).and_return(5)
        workflow = described_class.instantiate(job: job)

        expect(workflow.steps.order(:position).pluck(:kind)).to eq(
          %w[ prepare grader_fanout grader_collect summarize_amend push ]
        )
        expect(workflow.chain_template.first(3)).to eq([
          { "type" => "step", "kind" => "prepare" },
          { "type" => "retry_until", "max_iterations" => 5, "repair_first" => false,
            "repair" => [ "local_mode_handoff_fix" ], "check" => [ "grader_fanout", "grader_collect" ] },
          { "type" => "step", "kind" => "summarize_amend" }
        ])

        push_node = workflow.chain_template.last
        expect(push_node).to include("type" => "try", "step" => "push")
        expect(push_node.dig("on_failure", "remote_branch_advanced_rebase_conflict")).to include(
          { "type" => "step", "kind" => "push_agent_rebase" },
          { "type" => "step", "kind" => "push_after_rebase" }
        )
      end
    end
  end

  describe ".after_fail" do
    let(:job) do
      Factories.job_record(user: user, repository: repository, state: "running",
                           linked_chat_id: chat.id)
    end
    let(:workflow) { Workflow.create!(job: job, trigger_kind: "local_mode_handoff") }

    context "when failure was a grader failure" do
      before do
        Step.create!(workflow: workflow, kind: "grader_collect", position: 0,
                     iteration: 1, state: "failed")
      end

      it "marks the job failed after retry exhaustion" do
        described_class.after_fail(workflow)
        expect(job.reload).to be_failed
      end

      it "does not restore linked_chat_id" do
        job.update!(linked_chat_id: nil)
        described_class.after_fail(workflow)
        expect(job.reload.linked_chat_id).to be_nil
      end

      it "posts a passive failure report to the linked chat without queueing a chat-agent turn" do
        expect(ChatQueuedMessagePromoter).not_to receive(:deliver_one_if_idle!)

        expect {
          described_class.after_fail(workflow)
        }.to change { chat.messages.where(role: "system").count }.by(1)
          .and change { chat.chat_queued_messages.count }.by(0)

        msg = chat.messages.where(role: "system").last
        expect(msg.content["source"]).to eq("grader_report")
        expect(msg.content["text"]).to include("No chat-agent action is required")
      end

      it "does not post to the chat when no linked chat exists" do
        job.update!(linked_chat_id: nil)
        expect {
          described_class.after_fail(workflow)
        }.not_to change { chat.messages.count }
        expect(job.reload).to be_failed
      end
    end

    context "when failure was a non-grader failure (e.g. prepare)" do
      it "propagates the failure to the job (mark_failed!)" do
        described_class.after_fail(workflow)
        expect(job.reload).to be_failed
      end

      it "does not post to the linked chat" do
        expect {
          described_class.after_fail(workflow)
        }.not_to change { chat.messages.count }
      end
    end
  end

  describe ".after_success" do
    let(:job) do
      Factories.job_record(user: user, repository: repository, state: "implemented",
                           linked_chat_id: chat.id)
    end
    let(:workflow) { Workflow.create!(job: job, trigger_kind: "local_mode_handoff") }

    it "clears linked_chat_id after the handoff succeeds" do
      described_class.after_success(workflow)
      expect(job.reload.linked_chat_id).to be_nil
    end
  end

  describe ".grader_failure?" do
    let(:job) { Factories.job_record(user: user, repository: repository, state: "running") }
    let(:workflow) { Workflow.create!(job: job, trigger_kind: "local_mode_handoff") }

    it "returns true when grader_collect step is failed" do
      Step.create!(workflow: workflow, kind: "grader_collect", position: 0,
                   iteration: 1, state: "failed")
      expect(described_class.grader_failure?(workflow)).to be(true)
    end

    it "returns false when grader_collect is succeeded" do
      Step.create!(workflow: workflow, kind: "grader_collect", position: 0,
                   iteration: 1, state: "succeeded")
      expect(described_class.grader_failure?(workflow)).to be(false)
    end

    it "returns false when no grader_collect step exists" do
      expect(described_class.grader_failure?(workflow)).to be(false)
    end
  end

  describe "retry-loop dispatch" do
    let(:job) do
      Factories.job_record(user: user, repository: repository, state: "running",
                           linked_chat_id: nil)
    end

    it "runs a fresh local_mode_handoff_fix step after a failed grader iteration" do
      allow(AppSetting).to receive(:grade_max_iterations).and_return(3)
      workflow = described_class.instantiate(job: job)
      grader_collect = workflow.steps.find_by!(kind: "grader_collect")

      expect {
        StepDispatcher.fail_from(grader_collect)
      }.to change { workflow.steps.where(kind: "local_mode_handoff_fix", iteration: 2).count }.by(1)

      fix = workflow.steps.find_by!(kind: "local_mode_handoff_fix", iteration: 2)
      expect(fix.runs.count).to eq(1)
      expect(fix.loop_id).to eq(grader_collect.loop_id)
    end

    it "fails terminally after the configured max iterations" do
      allow(AppSetting).to receive(:grade_max_iterations).and_return(1)
      workflow = described_class.instantiate(job: job)
      grader_collect = workflow.steps.find_by!(kind: "grader_collect")
      grader_collect.update_column(:state, "failed")

      expect {
        StepDispatcher.fail_from(grader_collect)
      }.not_to change { workflow.steps.where(kind: "local_mode_handoff_fix").count }

      expect(workflow.reload).to be_failed
      expect(job.reload).to be_failed
    end
  end
end
