require "rails_helper"

RSpec.describe "Bug reports", type: :request do
  let(:user) { Factories.user }

  def upload_png(content: "\x89PNG\r\n\x1A\nscreenshot".b)
    Rack::Test::UploadedFile.new(
      StringIO.new(content),
      "image/png",
      original_filename: "capture.png"
    )
  end

  describe "layout entry point" do
    it "renders the floating bug-report control for signed-in app pages" do
      # root_path now redirects to chat; check the dashboard, which
      # renders the application layout (where the bug-report control
      # lives) directly.
      Factories.repository(user: user, owner: "tkadauke", name: "syrus")
      sign_in_as(user)

      get dashboard_jobs_path

      expect(response.body).to match(/data-controller="[^"]*\bform-validation\b/)
      expect(response.body).to include('data-controller="bug-report"')
      expect(response.body).to include('data-bug-context="Home#jobs"')
      expect(response.body).to include("Report a bug")
      expect(response.body).to include("No screenshot")
      expect(response.body).to include("bug_reports")
      expect(response.body).to include('class="fixed inset-0 m-auto max-h-[calc(100vh-2rem)]')
    end

    it "does not render the bug-report control on auth pages" do
      get new_session_path

      expect(response.body).not_to include("bug-report")
      expect(response.body).not_to include("Report a bug")
    end
  end

  describe "POST /bug_reports" do
    before { sign_in_as(user) }

    it "creates a queued direct Job for tkadauke/syrus with the selected screenshot attached" do
      repository = Factories.repository(user: user, owner: "tkadauke", name: "syrus")

      expect {
        post bug_reports_path, params: {
          title: "Home#index bug",
          description: "The dashboard fell over.",
          screenshot: upload_png
        }, headers: { "ACCEPT" => "application/json" }
      }.to change(Job, :count).by(1)
       .and change(Document, :count).by(1)
       .and change(Workflow, :count).by(1)

      expect(Run.count).to eq(0)

      job = Job.last
      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)).to include("message" => "Bug report queued.", "job_id" => job.id)
      expect(job).to have_attributes(
        user: user,
        repository: repository,
        kind: "direct",
        issue_number: nil,
        issue_title: "Home#index bug",
        issue_body: "Home#index bug\n\nThe dashboard fell over."
      )
      expect(job.workflows.first).to be_queued
      expect(job.runs).to be_empty

      attachment = job.job_attachments.last
      expect(attachment.source_url).to start_with("bug-report://")
      expect(attachment.filename).to eq("capture.png")
      expect(attachment.content_type).to eq("image/png")
      expect(attachment.file).to be_attached
      expect(attachment.file.download).to include("screenshot")
    end

    it "creates a queued direct Job without an attachment when no screenshot is selected" do
      repository = Factories.repository(user: user, owner: "tkadauke", name: "syrus")

      expect {
        post bug_reports_path, params: {
          title: "Home#index bug",
          description: "The dashboard fell over."
        }, headers: { "ACCEPT" => "application/json" }
      }.to change(Job, :count).by(1)
       .and change(Document, :count).by(0)
       .and change(Workflow, :count).by(1)

      job = Job.last
      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)).to include("message" => "Bug report queued.", "job_id" => job.id)
      expect(job).to have_attributes(
        user: user,
        repository: repository,
        kind: "direct",
        issue_number: nil,
        issue_title: "Home#index bug",
        issue_body: "Home#index bug\n\nThe dashboard fell over."
      )
      expect(job.job_attachments).to be_empty
    end

    it "keeps the HTML fallback on the originating page instead of the new job" do
      Factories.repository(user: user, owner: "tkadauke", name: "syrus")
      origin = dashboard_jobs_url

      post bug_reports_path, params: {
        title: "Home#index bug",
        description: "The dashboard fell over."
      }, headers: { "HTTP_REFERER" => origin }

      expect(response).to redirect_to(origin)
      expect(response).not_to redirect_to(job_path(Job.last))
    end

    it "requires the hardcoded repository to be configured for the user" do
      Factories.repository(user: user, owner: "acme", name: "widgets")

      expect {
        post bug_reports_path, params: {
          title: "Missing repo",
          description: "No target",
          screenshot: upload_png
        }
      }.not_to change(Job, :count)

      expect(response).to redirect_to(root_path)
      # root_path redirects to default_chat_path (chat), so the
      # alert lands two hops away. Follow until we reach a 200.
      follow_redirect! while response.redirect?
      expect(response.body).to include("Bug report repository tkadauke/syrus is not configured.")
    end
  end
end
