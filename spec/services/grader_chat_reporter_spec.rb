require "rails_helper"

RSpec.describe GraderChatReporter do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat) { ChatSession.create!(user: user, mode: "coding") }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "running", linked_chat_id: chat.id) }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "coding_handoff") }

  def grader_results(name:, required: true, status: "passed", duration_s: 1.2, output: nil)
    {
      "name" => name,
      "required" => required,
      "status" => status,
      "duration_s" => duration_s,
      "exit_code" => status == "passed" ? 0 : 1,
      "output" => output
    }
  end

  describe ".report_failure" do
    before do
      workflow.set_artifact!("iterations", [
        [
          grader_results(name: "rspec", status: "failed", output: "1 failure:\n  expected true, got false"),
          grader_results(name: "react-tests", status: "passed")
        ]
      ])
    end

    it "posts a system message with the grader report" do
      expect {
        described_class.report_failure(workflow: workflow, chat: chat)
      }.to change { chat.messages.where(role: "system").count }.by(1)

      message = chat.messages.where(role: "system").last
      expect(message.content["source"]).to eq("grader_report")
      expect(message.content["workflow_id"]).to eq(workflow.id)
      expect(message.content["text"]).to include("rspec")
      expect(message.content["text"]).to include("1 failure")
      expect(message.content["text"]).to include("complete_implement_step")
    end

    it "marks failing required graders with ✗" do
      described_class.report_failure(workflow: workflow, chat: chat)
      text = chat.messages.where(role: "system").last.content["text"]
      expect(text).to include("✗ **rspec** *(required)*")
    end

    it "marks passing graders with ✓" do
      described_class.report_failure(workflow: workflow, chat: chat)
      text = chat.messages.where(role: "system").last.content["text"]
      expect(text).to include("✓ **react-tests**")
    end

    it "creates a queued user message to trigger the agent turn" do
      expect {
        described_class.report_failure(workflow: workflow, chat: chat)
      }.to change { chat.chat_queued_messages.count }.by(1)

      # The message may be immediately delivered by deliver_one_if_idle! when the
      # chat is idle; use the unscoped association to find it regardless.
      queued = chat.chat_queued_messages.last
      expect(queued.content["source"]).to eq("grader_report")
      expect(queued.content["text"]).to include("complete_implement_step")
    end

    it "calls deliver_one_if_idle! to fire the agent turn when idle" do
      expect(ChatQueuedMessagePromoter).to receive(:deliver_one_if_idle!).with(chat)
      described_class.report_failure(workflow: workflow, chat: chat)
    end

    context "with no grader iteration data" do
      before { workflow.set_artifact!("iterations", []) }

      it "posts a graceful fallback message" do
        described_class.report_failure(workflow: workflow, chat: chat)
        text = chat.messages.where(role: "system").last.content["text"]
        expect(text).to include("No grader data recorded")
      end
    end
  end

  describe ".report_success" do
    it "posts a system message confirming graders passed" do
      expect {
        described_class.report_success(workflow: workflow, chat: chat)
      }.to change { chat.messages.where(role: "system").count }.by(1)

      message = chat.messages.where(role: "system").last
      expect(message.content["source"]).to eq("grader_report")
      expect(message.content["text"]).to include("All graders passed")
    end

    it "includes the PR URL when available" do
      allow(App::Presentation).to receive(:job_pr_url).with(job).and_return("https://github.com/owner/repo/pull/42")

      described_class.report_success(workflow: workflow, chat: chat)

      text = chat.messages.where(role: "system").last.content["text"]
      expect(text).to include("https://github.com/owner/repo/pull/42")
    end

    it "does not create a queued agent turn on success" do
      expect {
        described_class.report_success(workflow: workflow, chat: chat)
      }.not_to change { chat.queued_messages.count }
    end
  end
end
