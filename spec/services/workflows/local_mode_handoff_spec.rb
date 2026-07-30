require "rails_helper"

RSpec.describe Workflows::LocalModeHandoff do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat) { ChatSession.create!(user: user, mode: "coding") }

  describe ".steps_for" do
    context "when job has no PR yet" do
      let(:job) { Factories.job_record(user: user, repository: repository, state: "running") }

      it "includes prepare, grader_fanout, grader_collect, summarize, test_plan, pr_open" do
        kinds = described_class.steps_for(job)
        expect(kinds).to eq(%w[ prepare grader_fanout grader_collect summarize test_plan pr_open ])
      end

      it "omits prepare when job has skip_prepare_reason" do
        allow(job).to receive(:skip_prepare?).and_return(true)
        kinds = described_class.steps_for(job)
        expect(kinds).not_to include("prepare")
        expect(kinds).to include("grader_fanout", "grader_collect", "pr_open")
      end
    end

    context "when job already has a PR" do
      let(:job) { Factories.job_record(user: user, repository: repository, state: "implemented", pr_number: 42) }

      it "includes prepare, grader_fanout, grader_collect, summarize_amend and push chain" do
        kinds = described_class.steps_for(job)
        expect(kinds).to include("prepare", "grader_fanout", "grader_collect", "summarize_amend")
        expect(kinds).not_to include("pr_open")
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

      it "reverts the job to coding state" do
        described_class.after_fail(workflow)
        expect(job.reload).to be_coding
      end

      it "keeps linked_chat_id set" do
        described_class.after_fail(workflow)
        expect(job.reload.linked_chat_id).to eq(chat.id)
      end

      it "posts a failure report to the linked chat" do
        expect {
          described_class.after_fail(workflow)
        }.to change { chat.messages.where(role: "system").count }.by(1)

        msg = chat.messages.where(role: "system").last
        expect(msg.content["source"]).to eq("grader_report")
      end

      it "does not post to the chat when no linked chat exists" do
        job.update!(linked_chat_id: nil)
        expect {
          described_class.after_fail(workflow)
        }.not_to change { chat.messages.count }
        expect(job.reload).to be_coding
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
end
