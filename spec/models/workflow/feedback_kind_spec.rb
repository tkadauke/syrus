require "rails_helper"

RSpec.describe Workflow::FeedbackKind do
  let(:user)       { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job)        { Factories.job(repository: repository) }

  def build_workflow(trigger_kind:, artifacts: {})
    workflow = Workflow.create!(job: job, trigger_kind: trigger_kind)
    artifacts.each { |key, val| workflow.set_artifact!(key.to_s, val) }
    workflow
  end

  describe ".for" do
    it "returns nil for trigger kinds with no feedback kind" do
      workflow = build_workflow(trigger_kind: "ci_failure")
      expect(described_class.for(workflow)).to be_nil
    end

    it "returns a ChatFeedback instance for chat_feedback workflows" do
      workflow = build_workflow(trigger_kind: "chat_feedback")
      expect(described_class.for(workflow)).to be_a(described_class::ChatFeedback)
    end

    it "returns a PrComment instance for pr_comment and external_pr_feedback workflows" do
      expect(described_class.for(build_workflow(trigger_kind: "pr_comment"))).to be_a(described_class::PrComment)
      expect(described_class.for(build_workflow(trigger_kind: "external_pr_feedback"))).to be_a(described_class::PrComment)
    end
  end

  describe described_class::ChatFeedback do
    let(:workflow) do
      build_workflow(
        trigger_kind: "chat_feedback",
        artifacts: { "chat_feedback" => "Please refactor the helper.", "feedback_source" => { "chat_session_id" => 7 } }
      )
    end
    let(:feedback_kind) { described_class.new(workflow) }

    it "reports presence based on the chat_feedback artifact" do
      expect(feedback_kind.present?).to be true
      expect(described_class.new(build_workflow(trigger_kind: "chat_feedback")).present?).to be false
    end

    it "exposes plain_text, review_text, and history_body as the raw body" do
      expect(feedback_kind.plain_text).to eq("Please refactor the helper.")
      expect(feedback_kind.review_text).to eq("Please refactor the helper.")
      expect(feedback_kind.history_body).to eq("Please refactor the helper.")
    end

    it "returns nil review_text when the artifact is blank" do
      empty_workflow = build_workflow(trigger_kind: "chat_feedback", artifacts: { "chat_feedback" => "" })
      expect(described_class.new(empty_workflow).review_text).to be_nil
    end

    it "surfaces the feedback_source artifact" do
      expect(feedback_kind.feedback_source).to eq({ "chat_session_id" => 7 })
    end

    it "kind_name is chat_feedback" do
      expect(feedback_kind.kind_name).to eq("chat_feedback")
    end
  end

  describe described_class::PrComment do
    let(:comments) do
      [
        { "author" => "alice", "body" => "Please add tests.", "path" => nil, "line" => nil },
        { "author" => "bob", "body" => "Fix the typo.", "path" => "app/foo.rb", "line" => 12 }
      ]
    end
    let(:workflow) { build_workflow(trigger_kind: "pr_comment", artifacts: { "pr_comments" => comments }) }
    let(:feedback_kind) { described_class.new(workflow) }

    it "reports presence based on whether any pr_comments exist" do
      expect(feedback_kind.present?).to be true
      expect(described_class.new(build_workflow(trigger_kind: "pr_comment")).present?).to be false
    end

    it "joins plain bodies with no attribution" do
      expect(feedback_kind.plain_text).to eq("Please add tests.\n\nFix the typo.")
    end

    it "skips blank comment bodies in plain_text" do
      blank_workflow = build_workflow(
        trigger_kind: "pr_comment",
        artifacts: { "pr_comments" => [ { "body" => "" }, { "body" => "Non-blank." } ] }
      )
      expect(described_class.new(blank_workflow).plain_text).to eq("Non-blank.")
    end

    it "formats review_text with author attribution and inline path/line context" do
      expect(feedback_kind.review_text).to eq(
        "@alice: Please add tests.\n\n[Inline on app/foo.rb:12] @bob: Fix the typo."
      )
    end

    it "returns nil review_text when there are no comments" do
      empty_workflow = build_workflow(trigger_kind: "pr_comment")
      expect(described_class.new(empty_workflow).review_text).to be_nil
    end

    it "formats history_body with a simpler @author: body form" do
      expect(feedback_kind.history_body).to eq(
        "@alice: Please add tests.\n\n@bob: Fix the typo."
      )
    end

    it "kind_name is pr_comment" do
      expect(feedback_kind.kind_name).to eq("pr_comment")
    end
  end
end
