require "rails_helper"

RSpec.describe JobAttachment, type: :model do
  let(:job) { Factories.job }

  def uploaded_attachment(filename:, content_type:, content: "hello")
    described_class.new(job: job, attachment_type: "uploaded_file").tap do |attachment|
      attachment.file.attach(
        io: StringIO.new(content),
        filename: filename,
        content_type: content_type
      )
    end
  end

  it "accepts supported uploaded files" do
    attachment = uploaded_attachment(filename: "notes.md", content_type: "text/markdown")

    expect(attachment).to be_valid
  end

  it "rejects unsupported uploaded file types" do
    attachment = uploaded_attachment(filename: "archive.zip", content_type: "application/zip")

    expect(attachment).not_to be_valid
    expect(attachment.errors[:file]).to include("must be a PNG, JPG, GIF, WebP, PDF, plain text, or Markdown file")
  end

  it "rejects files over 20 MB" do
    attachment = uploaded_attachment(
      filename: "large.txt",
      content_type: "text/plain",
      content: "x" * (described_class::MAX_FILE_SIZE + 1)
    )

    expect(attachment).not_to be_valid
    expect(attachment.errors[:file]).to include("must be 20 MB or smaller")
  end

  it "stores Google Doc links without requiring an uploaded file" do
    attachment = described_class.new(
      job: job,
      attachment_type: "google_doc_link",
      google_doc_url: " https://docs.google.com/document/d/abc/edit "
    )

    expect(attachment).to be_valid
    attachment.save!
    expect(attachment.reload.google_doc_url).to eq("https://docs.google.com/document/d/abc/edit")
    expect(attachment.file).not_to be_attached
  end

  it "rejects non-Google Doc links" do
    attachment = described_class.new(
      job: job,
      attachment_type: "google_doc_link",
      google_doc_url: "https://example.com/doc"
    )

    expect(attachment).not_to be_valid
    expect(attachment.errors[:google_doc_url]).to include("must be a docs.google.com HTTPS URL")
  end

  it "limits each Job to 10 attachments" do
    10.times do |i|
      described_class.create!(
        job: job,
        attachment_type: "google_doc_link",
        google_doc_url: "https://docs.google.com/document/d/#{i}/edit"
      )
    end

    extra = described_class.new(
      job: job,
      attachment_type: "google_doc_link",
      google_doc_url: "https://docs.google.com/document/d/extra/edit"
    )

    expect(extra).not_to be_valid
    expect(extra.errors[:base]).to include("Jobs can have at most 10 attachments")
  end
end
