require "rails_helper"

RSpec.describe DirectJobs::Creator do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def png_attachment(name: "capture.png", content: "\x89PNG\r\n\x1A\nscreenshot".b)
    described_class::Attachment.new(source_url: "test://#{SecureRandom.uuid}", filename: name, content_type: "image/png", body: content)
  end

  it "creates a direct Job with an explicit title, immediately past triage" do
    result = described_class.new(user: user).call(repository: repository, prompt_text: "Do the thing.", title: "Explicit title")

    expect(result).to be_success
    expect(result.job).to have_attributes(
      user: user,
      repository: repository,
      kind: "direct",
      issue_number: nil,
      issue_title: "Explicit title",
      issue_body: "Do the thing.",
      title_pending: false,
      priority: "medium",
      state: "queued"
    )
  end

  it "leaves the title pending and enqueues title generation when no title is given" do
    result = nil
    expect {
      result = described_class.new(user: user).call(repository: repository, prompt_text: "Do the thing.")
    }.to have_enqueued_job(GenerateJobTitleJob)

    expect(result).to be_success
    expect(result.job).to have_attributes(title_pending: true, issue_title: GenerateJobTitleJob::PENDING_TITLE)
  end

  it "does not enqueue title generation when a title is given" do
    expect {
      described_class.new(user: user).call(repository: repository, prompt_text: "Do the thing.", title: "Explicit title")
    }.not_to have_enqueued_job(GenerateJobTitleJob)
  end

  it "attaches the given files to the created Job, in order" do
    first = png_attachment(name: "first.png")
    second = png_attachment(name: "second.png", content: "second content")

    result = described_class.new(user: user).call(repository: repository, prompt_text: "Do the thing.", attachments: [ first, second ])

    expect(result).to be_success
    expect(result.job.job_attachments.map(&:filename)).to eq([ "first.png", "second.png" ])
    expect(result.job.job_attachments.first.file.download).to eq("\x89PNG\r\n\x1A\nscreenshot".b)
  end

  it "creates no Job and returns the validation error when Job creation fails" do
    expect {
      result = described_class.new(user: user).call(repository: repository, prompt_text: "Do the thing.", priority: "not-a-real-priority")
      expect(result).not_to be_success
      expect(result.error).to be_present
    }.not_to change(Job, :count)
  end
end
