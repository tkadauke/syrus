require "rails_helper"

RSpec.describe JobImageAttachmentIngestor do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job(repository: repository) }
  let(:png_body) { "\x89PNG\r\n\x1A\nimage-data".b }

  before do
    allow(Addrinfo).to receive(:getaddrinfo).and_call_original
    allow(Addrinfo).to receive(:getaddrinfo)
      .with("uploads.example.com", nil, Socket::AF_UNSPEC, Socket::SOCK_STREAM)
      .and_return([instance_double(Addrinfo, ip_address: "93.184.216.34")])
  end

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
    expect(WebMock).to have_requested(:get, "https://uploads.example.com/mockup.png").
      with(headers: { "Accept-Encoding" => "identity" })
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

  it "stops reading a streamed response once it exceeds the byte cap" do
    stub_const("#{described_class}::MAX_BYTES", 12)
    yielded_chunks = []
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response["Content-Type"] = "image/png"
    response.define_singleton_method(:read_body) do |&block|
      [ "a" * 8, "b" * 8, "c" * 8 ].each do |chunk|
        yielded_chunks << chunk
        block.call(chunk)
      end
    end
    fake_http = instance_double(Net::HTTP)
    allow(fake_http).to receive(:request) do |request, &block|
      expect(request["Accept-Encoding"]).to eq("identity")
      block.call(response)
      response
    end
    allow(Net::HTTP).to receive(:start).and_yield(fake_http)

    result = described_class.ingest_markdown_images(
      job: job,
      markdown: "![stream](https://uploads.example.com/stream.png)"
    )

    expect(result.attached).to eq(0)
    expect(result.skipped).to eq(1)
    expect(job.job_attachments).to be_empty
    expect(yielded_chunks).to eq([ "a" * 8, "b" * 8 ])
  end

  it "stops a slow drip after the overall download deadline" do
    ingestor = described_class.new(job)
    allow(ingestor).to receive(:monotonic_now).and_return(100, 121)
    stub_request(:get, "https://uploads.example.com/slow.png").to_return(
      status: 200,
      headers: { "Content-Type" => "image/png" },
      body: png_body
    )

    result = ingestor.ingest_markdown_images("![slow](https://uploads.example.com/slow.png)")

    expect(result.attached).to eq(0)
    expect(result.skipped).to eq(1)
    expect(job.job_attachments).to be_empty
  end

  it "caps image URLs considered from a single comment" do
    stub_const("#{described_class}::MAX_URLS_PER_COMMENT", 2)
    stub_request(:get, %r{\Ahttps://uploads\.example\.com/mockup-\d+\.png\z}).to_return(
      status: 200,
      headers: { "Content-Type" => "image/png" },
      body: png_body
    )

    result = described_class.ingest_markdown_images(
      job: job,
      markdown: [
        "![one](https://uploads.example.com/mockup-1.png)",
        "![two](https://uploads.example.com/mockup-2.png)",
        "![three](https://uploads.example.com/mockup-3.png)"
      ].join("\n")
    )

    expect(result.attached).to eq(2)
    expect(result.skipped).to eq(0)
    expect(job.job_attachments.count).to eq(2)
    expect(WebMock).not_to have_requested(:get, "https://uploads.example.com/mockup-3.png")
  end

  it "does not run an unbounded regex over huge single-line comment markdown" do
    result = described_class.ingest_markdown_images(
      job: job,
      markdown: "![broken](#{'a' * 100_000}"
    )

    expect(result.attached).to eq(0)
    expect(result.skipped).to eq(0)
  end

  it "refuses to fetch images from private/internal network destinations" do
    result = described_class.ingest_markdown_images(
      job: job,
      markdown: <<~MARKDOWN
        ![metadata](http://169.254.169.254/latest/meta-data/)
        ![metadata-dot](http://169.254.169.254./latest/meta-data/)
        ![internal](http://127.0.0.1:6379/)
        ![short-loopback](http://127.1:6379/)
        ![decimal-loopback](http://2130706433:6379/)
      MARKDOWN
    )

    expect(result.attached).to eq(0)
    expect(result.skipped).to eq(5)
    expect(job.job_attachments).to be_empty
    expect(WebMock).not_to have_requested(:get, "http://169.254.169.254/latest/meta-data/")
    expect(WebMock).not_to have_requested(:get, "http://169.254.169.254./latest/meta-data/")
    expect(WebMock).not_to have_requested(:get, "http://127.0.0.1:6379/")
    expect(WebMock).not_to have_requested(:get, "http://127.1:6379/")
    expect(WebMock).not_to have_requested(:get, "http://2130706433:6379/")
  end
end
