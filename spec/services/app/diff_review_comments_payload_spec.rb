require "rails_helper"

RSpec.describe App::DiffReviewCommentsPayload do
  let(:user) { Factories.user }
  let(:job) { Factories.job_record(user: user) }

  it "returns comments as a flat list and grouped by file and line anchor" do
    first = job.diff_review_comments.create!(
      user: user,
      workflow: Workflow.create!(job: job, user: user, trigger_kind: "chat_feedback", state: "running"),
      surface: "job_source_diff",
      base_ref: "base",
      head_ref: "head",
      path: "app/models/widget.rb",
      side: "right",
      new_line: 12,
      body: "Add a spec.",
      context: { "severity" => "medium" }
    )
    second = job.diff_review_comments.create!(
      user: user,
      surface: "job_source_diff",
      path: "app/models/widget.rb",
      side: "left",
      old_line: 8,
      body: "This deletion looks stale."
    )

    payload = described_class.build(job: job, comments: [ first, second ])

    expect(payload[:job_id]).to eq(job.id)
    expect(payload[:comments].map { |comment| comment[:id] }).to eq([ first.id, second.id ])
    expect(payload.dig(:by_path, "app/models/widget.rb", "right::12").first).to include(
      id: first.id,
      path: "app/models/widget.rb",
      side: "right",
      new_line: 12,
      anchor_key: "right::12",
      user: include(id: user.id, display_name: user.display_name),
      workflow: include(id: first.workflow_id, trigger_kind: "chat_feedback", state: "running"),
      context: { "severity" => "medium" }
    )
    expect(payload.dig(:by_path, "app/models/widget.rb", "left:8:").first[:id]).to eq(second.id)
  end

  it "includes the parent id for reply comments" do
    parent = job.diff_review_comments.create!(
      user: user,
      surface: "job_review_workspace",
      anchor_kind: "review",
      body: "Nice work overall."
    )
    reply = parent.build_reply(user: user, body: "Thanks!").tap(&:save!)

    payload = described_class.build(job: job, comments: [ parent, reply ])

    expect(payload[:comments].find { |comment| comment[:id] == parent.id }[:parent_id]).to be_nil
    expect(payload[:comments].find { |comment| comment[:id] == reply.id }[:parent_id]).to eq(parent.id)
  end

  it "groups whole-review comments under a stable key instead of a nil path" do
    global = job.diff_review_comments.create!(
      user: user,
      surface: "job_review_workspace",
      anchor_kind: "review",
      body: "Nice work overall."
    )

    payload = described_class.build(job: job, comments: [ global ])

    expect(payload[:comments].first).to include(anchor_kind: "review", path: nil, anchor_key: "review")
    expect(payload.dig(:by_path, "__review__", "review").first[:id]).to eq(global.id)
  end
end
