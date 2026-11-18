require "rails_helper"

RSpec.describe Document, type: :model do
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
    expect(attachment.errors[:file]).to include("must be a supported text, PDF, Office, or image file")
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

  it "limits each Job to 10 attachments" do
    10.times do |i|
      uploaded_attachment(filename: "#{i}.txt", content_type: "text/plain").save!
    end

    extra = uploaded_attachment(filename: "extra.txt", content_type: "text/plain")

    expect(extra).not_to be_valid
    expect(extra.errors[:base]).to include("Jobs can have at most 10 attachments")
  end
end
