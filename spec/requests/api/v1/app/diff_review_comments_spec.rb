require "rails_helper"

RSpec.describe "App API diff review comments", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(user: user, repository: repo, issue_number: 42, issue_title: "Review diff") }

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)
  def comments_path(record = job) = "/api/v1/app/jobs/#{record.id}/diff_review_comments"
  def comment_path(comment, record = job) = "#{comments_path(record)}/#{comment.id}"

  def create_comment(**attrs)
    job.diff_review_comments.create!({
      user: user,
      surface: "job_source_diff",
      base_ref: "base-sha",
      head_ref: "head-sha",
      path: "app/models/widget.rb",
      side: "right",
      new_line: 12,
      body: "Please tighten this up.",
      state: "draft"
    }.merge(attrs))
  end

  describe "GET /api/v1/app/jobs/:job_id/diff_review_comments" do
    it "lists comments filtered by diff context and keyed by path and line anchor" do
      matching = create_comment
      create_comment(path: "app/models/other.rb")

      get comments_path, params: {
        surface: "job_source_diff",
        base_ref: "base-sha",
        head_ref: "head-sha",
        path: "app/models/widget.rb"
      }

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body["job_id"]).to eq(job.id)
      expect(body["comments"].map { |comment| comment["id"] }).to eq([ matching.id ])
      expect(body.dig("by_path", "app/models/widget.rb", "right::12").first).to include(
        "id" => matching.id,
        "path" => "app/models/widget.rb",
        "new_line" => 12,
        "anchor_key" => "right::12"
      )
    end

    it "allows read-tier repository members to list comments" do
      reader = Factories.user
      RepositoryMembership.create!(repository: repo, user: reader, role: "read")
      create_comment
      sign_in_as(reader)

      get comments_path

      expect(response).to have_http_status(:ok)
      expect(parse_body["comments"].size).to eq(1)
    end
  end

  describe "POST /api/v1/app/jobs/:job_id/diff_review_comments" do
    it "creates a comment for the current user" do
      workflow = Workflow.create!(job: job, user: user, trigger_kind: "initial", agent_provider: "claude")
      step = Step.create!(workflow: workflow, kind: "implement", position: 1)
      run = Run.create!(job: job, step: step, user: user, trigger_kind: "initial", agent_provider: "claude")

      expect {
        post comments_path,
             params: {
               diff_review_comment: {
                 surface: "job_source_diff",
                 base_ref: "base-sha",
                 head_ref: "head-sha",
                 path: "app/models/widget.rb",
                 side: "right",
                 new_line: 12,
                 diff_hunk: "@@ -10,2 +10,3 @@",
                 body: "Please add a regression spec.",
                 context: { symbol: "Widget#call" },
                 workflow_id: workflow.id,
                 run_id: run.id
               }
             },
             as: :json
      }.to change { job.diff_review_comments.count }.by(1)

      expect(response).to have_http_status(:created)
      comment = job.diff_review_comments.last
      expect(comment.user).to eq(user)
      expect(comment.workflow).to eq(workflow)
      expect(comment.run).to eq(run)
      expect(parse_body.dig("comments", 0)).to include(
        "id" => comment.id,
        "body" => "Please add a regression spec.",
        "context" => { "symbol" => "Widget#call" }
      )
    end

    it "lets write-tier repository members create comments" do
      writer = Factories.user
      RepositoryMembership.create!(repository: repo, user: writer, role: "write")
      sign_in_as(writer)

      post comments_path,
           params: {
             diff_review_comment: {
               path: "README.md",
               side: "right",
               new_line: 3,
               body: "Clarify this sentence."
             }
           },
           as: :json

      expect(response).to have_http_status(:created)
      expect(job.diff_review_comments.last.user).to eq(writer)
    end

    it "blocks read-tier repository members from creating comments" do
      reader = Factories.user
      RepositoryMembership.create!(repository: repo, user: reader, role: "read")
      sign_in_as(reader)

      post comments_path,
           params: { diff_review_comment: { path: "README.md", side: "right", new_line: 3, body: "Nope." } },
           as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it "rejects side and line coordinates that do not match" do
      post comments_path,
           params: {
             diff_review_comment: {
               path: "README.md",
               side: "left",
               new_line: 3,
               body: "This should use old_line."
             }
           },
           as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "message")).to include("left-side comments require old_line")
    end
  end

  describe "PATCH /api/v1/app/jobs/:job_id/diff_review_comments/:id" do
    it "updates comment content and state" do
      comment = create_comment

      patch comment_path(comment),
            params: {
              diff_review_comment: {
                body: "Resolved in the next patch.",
                state: "submitted",
                context: { severity: "low" }
              }
            },
            as: :json

      expect(response).to have_http_status(:ok)
      expect(comment.reload.body).to eq("Resolved in the next patch.")
      expect(comment.state).to eq("submitted")
      expect(comment.submitted_at).to be_present
      expect(comment.context).to eq("severity" => "low")
    end
  end

  describe "POST /api/v1/app/jobs/:job_id/diff_review_comments/:id/resolve" do
    it "resolves an existing comment" do
      comment = create_comment(state: "submitted")

      post "#{comment_path(comment)}/resolve", as: :json

      expect(response).to have_http_status(:ok)
      expect(comment.reload.state).to eq("resolved")
      expect(comment.resolved_at).to be_present
      expect(parse_body.dig("comments", 0, "state")).to eq("resolved")
    end
  end
end
