require "rails_helper"

RSpec.describe IngestIssueImagesJob do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:image_url) { "https://user-images.githubusercontent.com/1/screen.png" }
  let(:body) { "Screenshot:\n\n![screen](#{image_url})" }
  let(:job) { Factories.job(user: user, repository: repository, issue_number: 42, issue_body: body) }

  it "downloads issue images into uploaded_file JobAttachments" do
    stub_request(:head, image_url).to_return(
      status: 200,
      headers: { "Content-Type" => "image/png", "Content-Length" => "7" }
    )
    stub_request(:get, image_url).to_return(
      status: 200,
      headers: { "Content-Type" => "image/png" },
      body: "PNGDATA"
    )

    expect {
      described_class.perform_now(job.id)
    }.to change { job.job_attachments.count }.by(1)

    attachment = job.job_attachments.first
    expect(attachment).to be_uploaded_file
    expect(attachment.source_url).to eq(image_url)
    expect(attachment.content_type).to eq("image/png")
    expect(attachment.byte_size).to eq(7)
    expect(attachment.file).to be_attached
    expect(attachment.file.blob.filename.to_s).to eq("screen.png")
  end

  it "uses the repository installation token for GitHub asset URLs" do
    installation = Factories.installation(user: user, account_login: "acme")
    repository.update!(installation: installation)
    allow_any_instance_of(Installation).to receive(:fresh_token).and_return("ghs_installation")

    asset_url = "https://github.com/user-attachments/assets/abc-123"
    job.update!(issue_body: "![asset](#{asset_url})")
    stub_request(:head, asset_url)
      .with(headers: { "Authorization" => "Bearer ghs_installation" })
      .to_return(status: 200, headers: { "Content-Type" => "image/png", "Content-Length" => "4" })
    stub_request(:get, asset_url)
      .with(headers: { "Authorization" => "Bearer ghs_installation" })
      .to_return(status: 200, headers: { "Content-Type" => "image/png" }, body: "DATA")

    described_class.perform_now(job.id)

    expect(WebMock).to have_requested(:head, asset_url)
      .with(headers: { "Authorization" => "Bearer ghs_installation" })
    expect(job.job_attachments.first.file).to be_attached
  end

  it "skips images larger than 20 MB without creating an attachment" do
    stub_request(:head, image_url).to_return(
      status: 200,
      headers: { "Content-Type" => "image/png", "Content-Length" => (21.megabytes).to_s }
    )

    expect {
      described_class.perform_now(job.id)
    }.not_to change { job.job_attachments.count }
    expect(WebMock).not_to have_requested(:get, image_url)
  end

  it "skips non-image responses" do
    stub_request(:head, image_url).to_return(
      status: 200,
      headers: { "Content-Type" => "text/html", "Content-Length" => "7" }
    )

    expect {
      described_class.perform_now(job.id)
    }.not_to change { job.job_attachments.count }
  end

  it "deduplicates by source URL" do
    existing = job.job_attachments.create!(
      attachment_type: :uploaded_file,
      source_url: image_url,
      content_type: "image/png",
      byte_size: 7
    )

    expect {
      described_class.perform_now(job.id)
    }.not_to change { job.job_attachments.count }
    expect(job.job_attachments.first).to eq(existing)
    expect(WebMock).not_to have_requested(:head, image_url)
  end
end
