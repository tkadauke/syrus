require "rails_helper"

RSpec.describe JobAttachmentContext do
  let(:job) { Factories.job }

  it "downloads uploaded files into tmp/attachments and appends prompt context" do
    job.job_attachments.create!(attachment_type: "google_doc_link", google_doc_url: "https://docs.google.com/document/d/context/edit")
    upload = job.job_attachments.build(attachment_type: "uploaded_file")
    upload.file.attach(
      io: StringIO.new("mockup notes"),
      filename: "Mockup Notes.md",
      content_type: "text/markdown"
    )
    upload.save!

    Dir.mktmpdir do |dir|
      prompt = described_class.new(job: job, workspace_path: dir).apply_to("Original prompt")
      path = Dir[File.join(dir, "tmp/attachments/*")].first

      expect(File.read(path)).to eq("mockup notes")
      expect(prompt).to include("# Job Attachments")
      expect(prompt).to include("- Mockup Notes.md (text/markdown): tmp/attachments/#{File.basename(path)}")
      expect(prompt).to include("https://docs.google.com/document/d/context/edit")
    end
  end

  it "leaves prompts unchanged when a Job has no attachments" do
    Dir.mktmpdir do |dir|
      prompt = described_class.new(job: job, workspace_path: dir).apply_to("Original prompt")

      expect(prompt).to eq("Original prompt")
      expect(File).not_to exist(File.join(dir, "tmp/attachments"))
    end
  end
end
