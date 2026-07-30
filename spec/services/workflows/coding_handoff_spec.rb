require "rails_helper"

RSpec.describe Workflows::CodingHandoff do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat) { ChatSession.create!(user: user, mode: "coding") }

  def enable_coding_mode!
    feature = Feature.find_or_create_by!(slug: "coding_mode") do |record|
      record.category = "Labs"
      record.name = "Coding Mode"
    end
    feature.update!(enabled: true)
  end

  describe ".steps_for" do
    let(:job) { Factories.job_record(user: user, repository: repository, state: "implemented") }

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

  describe ".after_success" do
    before { enable_coding_mode! }

    let(:job) do
      Factories.job_record(user: user, repository: repository, state: "implemented",
                           linked_chat_id: chat.id)
    end
    let(:workflow) { Workflow.create!(job: job, trigger_kind: "coding_handoff") }

    it "clears linked_chat_id on the job" do
      described_class.after_success(workflow)
      expect(job.reload.linked_chat_id).to be_nil
    end

    it "posts a success system message to the linked chat" do
      expect {
        described_class.after_success(workflow)
      }.to change { chat.messages.where(role: "system").count }.by(1)

      msg = chat.messages.where(role: "system").last
      expect(msg.content["source"]).to eq("grader_report")
      expect(msg.content["text"]).to include("All graders passed")
    end

    it "keeps linked_chat_id available while reporting success and clears it afterward" do
      allow(GraderChatReporter).to receive(:report_success) do |workflow:, chat:|
        expect(workflow.job.reload.linked_chat_id).to eq(chat.id)
      end
      allow(ChatCodingWorkspaceReclaimJob).to receive(:perform_later) do |chat_id|
        expect(chat_id).to eq(chat.id)
        expect(job.reload.linked_chat_id).to eq(chat.id)
      end

      described_class.after_success(workflow)

      expect(GraderChatReporter).to have_received(:report_success).with(workflow: workflow, chat: chat)
      expect(ChatCodingWorkspaceReclaimJob).to have_received(:perform_later).with(chat.id)
      expect(job.reload.linked_chat_id).to be_nil
    end

    it "is a no-op when coding_mode feature is disabled" do
      Feature.find_by(slug: "coding_mode")&.update!(enabled: false)

      expect {
        described_class.after_success(workflow)
      }.not_to change { chat.messages.count }

      expect(job.reload.linked_chat_id).to eq(chat.id)
    end

    it "is a no-op when linked_chat_id is nil" do
      job.update!(linked_chat_id: nil)
      expect {
        described_class.after_success(workflow)
      }.not_to have_enqueued_job(ChatCodingWorkspaceReclaimJob)
    end

    it "enqueues a coding-workspace reclaim on the chat queue (branch is pushed)" do
      expect {
        described_class.after_success(workflow)
      }.to have_enqueued_job(ChatCodingWorkspaceReclaimJob).with(chat.id).on_queue("chat")
    end
  end

  describe ".after_fail" do
    before { enable_coding_mode! }

    let(:job) do
      Factories.job_record(user: user, repository: repository, state: "running",
                           linked_chat_id: chat.id)
    end
    let(:workflow) { Workflow.create!(job: job, trigger_kind: "coding_handoff") }

    context "when failure was a grader failure" do
      before do
        step = Step.create!(workflow: workflow, kind: "grader_collect", position: 0,
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

    context "when coding_mode feature is disabled" do
      before do
        Feature.find_by(slug: "coding_mode")&.update!(enabled: false)
        Step.create!(workflow: workflow, kind: "grader_collect", position: 0,
                     iteration: 1, state: "failed")
      end

      it "is a no-op" do
        described_class.after_fail(workflow)
        # no state change from the hook
        expect(job.reload).to be_running
      end
    end
  end

  describe ".grader_failure?" do
    let(:job) { Factories.job_record(user: user, repository: repository, state: "running") }
    let(:workflow) { Workflow.create!(job: job, trigger_kind: "coding_handoff") }

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
