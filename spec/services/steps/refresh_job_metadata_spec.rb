require "rails_helper"

RSpec.describe Steps::RefreshJobMetadata do
  let(:user)       { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job)        { Factories.job(repository: repository) }

  def build_handler(trigger_kind:, artifacts: {})
    workflow = Workflow.create!(job: job, trigger_kind: trigger_kind)
    artifacts.each { |key, val| workflow.set_artifact!(key.to_s, val) }
    step = Step.create!(workflow: workflow, kind: "refresh_job_metadata", position: 0)
    run  = Run.create!(job: job, step: step, trigger_kind: trigger_kind)
    run.start! && run.save!
    described_class.new(run)
  end

  describe "#feedback_text (private)" do
    context "when trigger_kind is pr_comment" do
      it "joins pr_comments bodies with double newlines" do
        comments = [
          { "body" => "Please add tests." },
          { "body" => "Also fix the typo." }
        ]
        handler = build_handler(trigger_kind: "pr_comment", artifacts: { pr_comments: comments })

        result = handler.send(:feedback_text)
        expect(result).to eq("Please add tests.\n\nAlso fix the typo.")
      end

      it "skips blank comment bodies" do
        comments = [{ "body" => "" }, { "body" => "Non-blank." }]
        handler = build_handler(trigger_kind: "pr_comment", artifacts: { pr_comments: comments })

        expect(handler.send(:feedback_text)).to eq("Non-blank.")
      end

      it "returns empty string when no pr_comments artifact" do
        handler = build_handler(trigger_kind: "pr_comment")
        expect(handler.send(:feedback_text)).to eq("")
      end
    end

    context "when trigger_kind is chat_feedback" do
      it "returns the chat_feedback artifact as a string" do
        handler = build_handler(trigger_kind: "chat_feedback", artifacts: { chat_feedback: "Please refactor the helper." })
        expect(handler.send(:feedback_text)).to eq("Please refactor the helper.")
      end

      it "returns empty string when no chat_feedback artifact" do
        handler = build_handler(trigger_kind: "chat_feedback")
        expect(handler.send(:feedback_text)).to eq("")
      end
    end

    context "when trigger_kind has no feedback kind (e.g. ci_failure)" do
      it "returns nil" do
        handler = build_handler(trigger_kind: "ci_failure")
        expect(handler.send(:feedback_text)).to be_nil
      end
    end
  end
end
