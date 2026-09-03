require "rails_helper"

RSpec.describe DiffReviewComment do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repo) }

  def build_comment(**attrs)
    described_class.new({
      job: job,
      user: user,
      surface: "job_source_diff",
      base_ref: "base-sha",
      head_ref: "head-sha",
      path: "app/models/widget.rb",
      side: "right",
      new_line: 12,
      diff_hunk: "@@ -10,2 +10,3 @@",
      context: { "symbol" => "Widget#call" },
      body: "This needs a spec.",
      state: "draft"
    }.merge(attrs))
  end

  it "creates a durable diff anchor" do
    comment = build_comment

    expect(comment.save).to be true
    expect(comment.anchor_key).to eq("right::12")
    expect(comment.context).to eq("symbol" => "Widget#call")
  end

  it "requires a path, side, body, state, and at least one line coordinate" do
    comment = build_comment(path: "", side: "middle", body: "", state: "unknown", old_line: nil, new_line: nil)

    expect(comment).not_to be_valid
    expect(comment.errors[:path]).to be_present
    expect(comment.errors[:side]).to be_present
    expect(comment.errors[:body]).to be_present
    expect(comment.errors[:state]).to be_present
    expect(comment.errors[:base]).to include("old_line or new_line must be present")
  end

  it "requires optional workflow and run links to belong to the same job" do
    other_job = Factories.job_record(repository: repo, issue_number: 43)
    other_workflow = Workflow.create!(job: other_job, user: user, trigger_kind: "initial", agent_provider: "claude")
    other_run = Run.create!(job: other_job, trigger_kind: "initial", agent_provider: "claude")
    comment = build_comment(workflow: other_workflow, run: other_run)

    expect(comment).not_to be_valid
    expect(comment.errors[:workflow]).to include("must belong to the same job")
    expect(comment.errors[:run]).to include("must belong to the same job")
  end

  it "stamps lifecycle timestamps when state changes" do
    comment = build_comment.tap(&:save!)

    expect {
      comment.resolve!
    }.to change { comment.reload.resolved_at }.from(nil)
    expect(comment.state).to eq("resolved")
  end
end
