require "rails_helper"

RSpec.describe DiffReviewCommentFeedbackSubmission do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "implemented", issue_title: "Reviewable diff") }

  before { clear_enqueued_jobs }

  def create_comment(**attrs)
    job.diff_review_comments.create!({
      user: user,
      surface: "job_source_diff",
      base_ref: "base-sha",
      head_ref: "head-sha",
      path: "app/models/widget.rb",
      side: "right",
      new_line: 12,
      diff_hunk: "@@ -10,2 +10,3 @@\n def call\n+  true",
      context: { "symbol" => "Widget#call" },
      body: "Please add a regression spec.",
      state: "draft"
    }.merge(attrs))
  end

  it "creates chat feedback with readable text and structured diff comment artifacts" do
    first = create_comment
    second = create_comment(path: "app/controllers/widgets_controller.rb", new_line: 7, body: "Guard this action.")

    result = described_class.call(job: job, comment_ids: [ second.id, first.id ], actor: user)

    expect(result).to be_success
    workflow = result.workflow
    expect(workflow).to have_attributes(trigger_kind: "chat_feedback")
    expect(workflow.artifact("chat_feedback")).to include("Please address these 2 anchored diff review comments.")
    expect(workflow.artifact("chat_feedback")).to include("app/models/widget.rb:12")
    expect(workflow.artifact("feedback_source")).to include(
      "kind" => "diff_review_comments",
      "diff_review_comment_ids" => [ second.id, first.id ],
      "submitted_by_user_id" => user.id
    )
    expect(workflow.artifact("diff_comments")).to contain_exactly(
      hash_including(
        "id" => first.id,
        "path" => "app/models/widget.rb",
        "side" => "right",
        "new_line" => 12,
        "base_ref" => "base-sha",
        "head_ref" => "head-sha",
        "diff_hunk" => a_string_including("@@ -10,2 +10,3 @@"),
        "context" => { "symbol" => "Widget#call" },
        "body" => "Please add a regression spec."
      ),
      hash_including("id" => second.id, "path" => "app/controllers/widgets_controller.rb", "body" => "Guard this action.")
    )
  end

  it "marks selected comments submitted and links them to the workflow after acceptance" do
    comment = create_comment

    result = described_class.call(job: job, comment_ids: [ comment.id ], actor: user)

    expect(result).to be_success
    expect(comment.reload).to have_attributes(state: "submitted", workflow: result.workflow)
    expect(comment.submitted_at).to be_present
  end

  it "rejects blank selection before creating a workflow" do
    expect {
      result = described_class.call(job: job, comment_ids: [], actor: user)
      expect(result).not_to be_success
      expect(result.error).to include("Select at least one")
    }.not_to change { job.workflows.count }
  end

  it "rejects selections with no unresolved comments" do
    comment = create_comment(state: "resolved", resolved_at: Time.current)

    result = described_class.call(job: job, comment_ids: [ comment.id ], actor: user)

    expect(result).not_to be_success
    expect(result.error).to include("No unresolved diff comments")
    expect(job.workflows.where(trigger_kind: "chat_feedback")).to be_empty
  end

  it "rejects duplicate active chat feedback workflows through the shared guard" do
    create_comment
    active = Workflow.create!(job: job, user: user, trigger_kind: "chat_feedback", state: "running")
    attach_work_unit(active, kind: "chat_feedback", state: "running")

    result = described_class.call(job: job, comment_ids: job.diff_review_comments.pluck(:id), actor: user)

    expect(result).not_to be_success
    expect(result.error).to eq("a chat_feedback workflow is already queued or running for this job")
    expect(job.workflows.where(trigger_kind: "chat_feedback").count).to eq(1)
  end

  it "unapproves approved jobs through ChatFeedbackSubmission" do
    approved = Factories.job_record(user: user, repository: repository, state: "approved", approved_at: Time.current)
    comment = create_comment
    comment.update!(job: approved)

    result = described_class.call(job: approved, comment_ids: [ comment.id ], actor: user)

    expect(result).to be_success
    expect(approved.reload).to be_implemented
    expect(approved.approved_at).to be_nil
  end
end
