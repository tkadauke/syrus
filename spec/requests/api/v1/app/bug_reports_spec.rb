require "rails_helper"

RSpec.describe "API: /api/v1/app/bug_reports", type: :request do
  let(:user) { Factories.user }

  around do |example|
    old_owner = ENV["SYRUS_BUG_REPORT_OWNER"]
    ENV["SYRUS_BUG_REPORT_OWNER"] = "operator"
    example.run
  ensure
    old_owner.nil? ? ENV.delete("SYRUS_BUG_REPORT_OWNER") : ENV["SYRUS_BUG_REPORT_OWNER"] = old_owner
  end

  def parse_body
    JSON.parse(response.body)
  end

  def upload_png(content: "\x89PNG\r\n\x1A\nscreenshot".b)
    Rack::Test::UploadedFile.new(
      StringIO.new(content),
      "image/png",
      original_filename: "capture.png"
    )
  end

  it "401s with a JSON error when signed out" do
    post "/api/v1/app/bug_reports", params: { title: "Unauthed" }

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "creates a direct Job for the configured Syrus bug-report repository" do
    repository = Factories.repository(user: user, owner: "operator", name: "syrus")
    sign_in_as(user)

    expect {
      post "/api/v1/app/bug_reports", params: {
        title: "Home#index bug",
        description: "The dashboard fell over.",
        screenshot: upload_png
      }
    }.to change(Job, :count).by(1)
      .and change(Document, :count).by(1)
      .and change(Workflow, :count).by(1)
      .and change(Run, :count).by(1)

    job = Job.last
    expect(response).to have_http_status(:created)
    expect(parse_body).to include("message" => "Bug report queued.", "job_id" => job.id)
    expect(job).to have_attributes(
      user: user,
      repository: repository,
      kind: "direct",
      issue_number: nil,
      issue_title: "Home#index bug",
      issue_body: "Home#index bug\n\nThe dashboard fell over."
    )
    expect(job.job_attachments.last.filename).to eq("capture.png")
  end

  it "returns structured validation errors" do
    Factories.repository(user: user, owner: "acme", name: "widgets")
    sign_in_as(user)

    expect {
      post "/api/v1/app/bug_reports", params: { title: "Missing repo" }
    }.not_to change(Job, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
    expect(parse_body.dig("error", "message")).to eq("Bug report repository operator/syrus is not configured.")
  end
end
