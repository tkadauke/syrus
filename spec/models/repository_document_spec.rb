require "rails_helper"

RSpec.describe RepositoryDocument, type: :model do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  def upload(filename:, content_type:, content: "hello")
    Rack::Test::UploadedFile.new(
      StringIO.new(content),
      content_type,
      original_filename: filename
    )
  end

  it "accepts a supported file attachment and defaults a blank title to the filename" do
    document = repo.repository_documents.create!(
      user: user,
      kind: "file",
      title: "",
      file: upload(filename: "architecture.md", content_type: "text/markdown")
    )

    expect(document.title).to eq("architecture.md")
    expect(document.file).to be_attached
  end

  it "accepts Office Open XML documents" do
    document = repo.repository_documents.new(
      user: user,
      kind: "file",
      title: "Spreadsheet",
      file: upload(
        filename: "inventory.xlsx",
        content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      )
    )

    expect(document).to be_valid
  end

  it "rejects unsupported file types" do
    document = repo.repository_documents.new(
      user: user,
      kind: "file",
      title: "Archive",
      file: upload(filename: "archive.zip", content_type: "application/zip")
    )

    expect(document).not_to be_valid
    expect(document.errors[:file]).to include("must be a supported text, PDF, Office, or image file")
  end

  it "rejects Google Docs fields on file documents" do
    document = repo.repository_documents.new(
      user: user,
      kind: "file",
      title: "Mixed",
      google_docs_url: "https://docs.google.com/document/d/example/edit",
      file: upload(filename: "notes.txt", content_type: "text/plain")
    )

    expect(document).not_to be_valid
    expect(document.errors[:google_docs_url]).to include("must be blank for file documents")
  end

  it "rejects files larger than 20 MB" do
    document = repo.repository_documents.new(
      user: user,
      kind: "file",
      title: "Too large",
      file: upload(filename: "huge.txt", content_type: "text/plain", content: "x" * (20.megabytes + 1))
    )

    expect(document).not_to be_valid
    expect(document.errors[:file]).to include("must be 20 MB or smaller")
  end

  it "stores Google Docs links without fetching or validating accessibility" do
    document = repo.repository_documents.create!(
      user: user,
      kind: "google_doc",
      title: "",
      google_docs_url: "https://docs.google.com/document/d/private/edit"
    )

    expect(document.title).to eq("Google Doc")
    expect(document.google_docs_url).to eq("https://docs.google.com/document/d/private/edit")
    expect(document.file).not_to be_attached
  end

  it "limits cached Google Docs content to 64 KB" do
    document = repo.repository_documents.new(
      user: user,
      kind: "google_doc",
      title: "Spec",
      google_docs_url: "https://docs.google.com/document/d/example/edit",
      content_cache: "x" * (64.kilobytes + 1)
    )

    expect(document).not_to be_valid
    expect(document.errors[:content_cache]).to include("must be 64 KB or smaller")
  end
end
