require "rails_helper"

RSpec.describe Document, type: :model do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }
  let(:job) { Factories.job(repository: repo) }

  def upload(filename: "notes.txt", content_type: "text/plain", content: "hello")
    Rack::Test::UploadedFile.new(
      StringIO.new(content),
      content_type,
      original_filename: filename
    )
  end

  it "attaches to a User" do
    document = user.documents.create!(
      kind: "file",
      user: user,
      file: upload
    )

    expect(document.attachable).to eq(user)
    expect(document.title).to eq("notes.txt")
  end

  it "attaches to a Repository" do
    document = repo.documents.create!(
      kind: "google_doc",
      user: user,
      google_doc_url: "https://docs.google.com/document/d/repo/edit"
    )

    expect(document.attachable).to eq(repo)
    expect(repo.repository_documents).to include(document)
  end

  it "attaches to a Job" do
    document = job.documents.create!(
      kind: "google_doc",
      user: user,
      google_doc_url: "https://docs.google.com/document/d/job/edit"
    )

    expect(document.attachable).to eq(job)
    expect(job.job_attachments).to include(document)
  end

  describe "ACCEPTED_FILE_CONTENT_TYPES" do
    it "accepts text/html, text/css, and text/javascript (preview panel mockup files)" do
      %w[text/html text/css text/javascript].each do |content_type|
        document = job.documents.create!(
          kind: "file",
          user: user,
          file: upload(filename: "mockup.#{content_type.split('/').last}", content_type: content_type, content: "body {}")
        )

        expect(document).to be_valid
      end
    end

    it "rejects an unsupported content type" do
      document = job.job_attachments.build(
        kind: "file",
        user: user,
        file: upload(filename: "archive.zip", content_type: "application/zip", content: "PK")
      )

      expect(document).not_to be_valid
      expect(document.errors[:file]).to include("must be a supported text, PDF, Office, or image file")
    end
  end

  it "localizes attachment limit interpolation in German and Latin" do
    document = job.documents.build(kind: "google_doc", user: user, google_doc_url: "https://docs.google.com/document/d/test/edit")
    allow(job.documents).to receive(:count).and_return(Document::MAX_ATTACHMENTS_PER_JOB)

    expect(I18n.with_locale(:de) { document.valid?; document.errors[:base] }).to include("Jobs dürfen höchstens 10 Anhänge haben")
    expect(I18n.with_locale(:la) { document.valid?; document.errors[:base] }).to include("Jobs non plus quam 10 adiuncta habere possunt")
  end
end
