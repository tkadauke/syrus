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
      Factories.repository(user: user, owner: "tkadauke", name: "syrus")
      sign_in_as(user)

      get root_path

      expect(response.body).to include('data-controller="form-validation"')
      expect(response.body).to include('data-controller="bug-report"')
      expect(response.body).to include('data-bug-context="Home#index"')
      expect(response.body).to include("Report a bug")
      expect(response.body).to include("bug_reports")
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
        }
      }.to change(Job, :count).by(1)
       .and change(Document, :count).by(1)
       .and change(Workflow, :count).by(1)

      expect(Run.count).to eq(0)

      job = Job.last
      expect(response).to redirect_to(job_path(job))
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
      follow_redirect!
      expect(response.body).to include("Bug report repository tkadauke/syrus is not configured.")
    end
  end
end
