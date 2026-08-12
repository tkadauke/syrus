require "rails_helper"

RSpec.describe JobImageAttachmentIngestor do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job(repository: repository) }
  let(:png_body) { "\x89PNG\r\n\x1A\nimage-data".b }

  it "extracts markdown images, downloads them, and stores job documents" do
    stub_request(:get, "https://uploads.example.com/mockup.png").to_return(
      status: 200,
      headers: { "Content-Type" => "image/png", "Content-Length" => png_body.bytesize.to_s },
      body: png_body
    )

    result = described_class.ingest_markdown_images(
      job: job,
      markdown: "Please match this: ![mockup](https://uploads.example.com/mockup.png)"
    )

    expect(result.attached).to eq(1)
    attachment = job.job_attachments.last
    expect(attachment.source_url).to eq("https://uploads.example.com/mockup.png")
    expect(attachment.content_type).to eq("image/png")
    expect(attachment.file).to be_attached
    expect(attachment.file.download).to eq(png_body)
  end

  it "deduplicates by source URL per Job" do
    stub_request(:get, "https://uploads.example.com/mockup.png").to_return(
      status: 200,
      headers: { "Content-Type" => "image/png" },
      body: png_body
    )

    markdown = <<~MARKDOWN
      ![first](https://uploads.example.com/mockup.png)
      ![second](https://uploads.example.com/mockup.png)
    MARKDOWN

    described_class.ingest_markdown_images(job: job, markdown: markdown)
    result = described_class.ingest_markdown_images(job: job, markdown: markdown)

    expect(result.attached).to eq(0)
    expect(job.job_attachments.count).to eq(1)
    expect(WebMock).to have_requested(:get, "https://uploads.example.com/mockup.png").once
  end

  it "skips non-image and oversized responses without raising" do
    stub_request(:get, "https://uploads.example.com/readme.txt").to_return(
      status: 200,
      headers: { "Content-Type" => "text/plain" },
      body: "not an image"
    )
    stub_request(:get, "https://uploads.example.com/huge.png").to_return(
      status: 200,
      headers: {
        "Content-Type" => "image/png",
        "Content-Length" => (described_class::MAX_BYTES + 1).to_s
      },
      body: ""
    )

    result = described_class.ingest_markdown_images(
      job: job,
      markdown: "![text](https://uploads.example.com/readme.txt) ![huge](https://uploads.example.com/huge.png)"
    )

    expect(result.attached).to eq(0)
    expect(result.skipped).to eq(2)
    expect(job.job_attachments).to be_empty
  end

  it "does not run an unbounded regex over huge single-line comment markdown" do
    result = described_class.ingest_markdown_images(
      job: job,
      markdown: "![broken](#{'a' * 100_000}"
    )

    expect(result.attached).to eq(0)
    expect(result.skipped).to eq(0)
  end
end
