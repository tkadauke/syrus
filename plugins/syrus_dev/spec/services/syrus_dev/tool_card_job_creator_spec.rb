require "rails_helper"

RSpec.describe SyrusDev::ToolCardJobCreator do
  let(:user) { Factories.user }

  def png_base64(content: "\x89PNG\r\n\x1A\nscreenshot".b)
    Base64.strict_encode64(content)
  end

  context "when the configured report-issue repository exists" do
    let!(:repository) { Factories.repository(user: user, owner: "tkadauke", name: "syrus") }

    it "creates a direct Job with a pending title, immediately past triage, using the supplied prompt" do
      result = nil
      expect {
        result = described_class.new(user: user).call(prompt: "The card renders the wrong icon.")
      }.to have_enqueued_job(GenerateJobTitleJob)

      expect(result).to be_success
      job = result.job
      expect(job).to have_attributes(
        user: user,
        repository: repository,
        kind: "direct",
        issue_number: nil,
        issue_body: "The card renders the wrong icon.",
        title_pending: true,
        state: "queued"
      )
      expect(job.job_attachments).to be_empty
    end

    it "attaches the given screenshot to the created Job" do
      result = described_class.new(user: user).call(
        prompt: "Look at this.",
        screenshot: { name: "capture.png", mime_type: "image/png", data: png_base64 }
      )

      expect(result).to be_success
      attachment = result.job.job_attachments.last
      expect(attachment.filename).to eq("capture.png")
      expect(attachment.content_type).to eq("image/png")
      expect(attachment.file.download).to eq("\x89PNG\r\n\x1A\nscreenshot".b)
    end

    it "rejects a blank prompt without creating a Job" do
      expect {
        result = described_class.new(user: user).call(prompt: "   ")
        expect(result).not_to be_success
        expect(result.error).to eq("Prompt can't be blank.")
      }.not_to change(Job, :count)
    end

    it "rejects a non-PNG screenshot without creating a Job" do
      expect {
        result = described_class.new(user: user).call(
          prompt: "Look at this.",
          screenshot: { name: "capture.jpg", mime_type: "image/jpeg", data: Base64.strict_encode64("not a png") }
        )
        expect(result).not_to be_success
        expect(result.error).to eq("Screenshot must be a PNG.")
      }.not_to change(Job, :count)
    end

    it "allows string or symbol keys for the screenshot hash" do
      result = described_class.new(user: user).call(
        prompt: "Look at this.",
        screenshot: { "name" => "capture.png", "mime_type" => "image/png", "data" => png_base64 }
      )

      expect(result).to be_success
      expect(result.job.job_attachments.last.filename).to eq("capture.png")
    end
  end

  it "fails without creating a Job when no report-issue repository is configured for this user" do
    expect {
      result = described_class.new(user: user).call(prompt: "Look at this.")
      expect(result).not_to be_success
      expect(result.error).to eq("Tool Card jobs are only available when this instance can file Syrus Jobs for itself.")
    }.not_to change(Job, :count)
  end
end
