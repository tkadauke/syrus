require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/tool_card_jobs", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let!(:non_admin) { Factories.user(admin: false) }

  def parse_body = JSON.parse(response.body)

  def png_base64(content: "\x89PNG\r\n\x1A\nscreenshot".b)
    Base64.strict_encode64(content)
  end

  before do
    PluginRecord.find_by!(name: "syrus_dev").update!(enabled: true)
  end

  it "401s with a JSON error when signed out" do
    post "/api/v1/app/admin/tool_card_jobs", params: { prompt: "Look at this." }

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "403s with a JSON error for non-admin users" do
    sign_in_as(non_admin)

    post "/api/v1/app/admin/tool_card_jobs", params: { prompt: "Look at this." }

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "404s when the syrus_dev plugin is disabled" do
    PluginRecord.find_by!(name: "syrus_dev").update!(enabled: false)
    sign_in_as(admin)

    post "/api/v1/app/admin/tool_card_jobs", params: { prompt: "Look at this." }

    expect(response).to have_http_status(:not_found)
    expect(parse_body["error"]).to eq("syrus_dev_plugin_disabled")
  end

  context "when the configured report-issue repository exists" do
    let!(:repository) { Factories.repository(user: admin, owner: "tkadauke", name: "syrus") }

    it "immediately creates a direct Job with the prompt and screenshot, bypassing chat" do
      sign_in_as(admin)

      expect {
        post "/api/v1/app/admin/tool_card_jobs", params: {
          prompt: "This card renders the wrong icon.",
          screenshot: { name: "capture.png", mime_type: "image/png", data: png_base64 }
        }
      }.to change(Job, :count).by(1)
        .and change(Document, :count).by(1)
        .and change(Workflow, :count).by(1)
        .and change(Run, :count).by(1)
        .and have_enqueued_job(GenerateJobTitleJob)

      job = Job.last
      expect(response).to have_http_status(:created)
      expect(parse_body).to include("message" => "Job created.", "redirect_to" => job_path(job))
      expect(parse_body.dig("job", "id")).to eq(job.id)
      expect(job).to have_attributes(user: admin, repository: repository, kind: "direct", issue_body: "This card renders the wrong icon.")
      expect(job.job_attachments.last.filename).to eq("capture.png")
    end

    it "creates a Job without a screenshot when none is supplied" do
      sign_in_as(admin)

      expect {
        post "/api/v1/app/admin/tool_card_jobs", params: { prompt: "No screenshot this time." }
      }.to change(Job, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(Job.last.job_attachments).to be_empty
    end

    it "returns a validation error for a blank prompt without creating a Job" do
      sign_in_as(admin)

      expect {
        post "/api/v1/app/admin/tool_card_jobs", params: { prompt: "   " }
      }.not_to change(Job, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("validation_failed")
      expect(parse_body.dig("error", "message")).to eq("Prompt can't be blank.")
    end
  end

  it "returns a validation error when no report-issue repository is configured for this admin" do
    sign_in_as(admin)

    expect {
      post "/api/v1/app/admin/tool_card_jobs", params: { prompt: "Look at this." }
    }.not_to change(Job, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
  end
end
