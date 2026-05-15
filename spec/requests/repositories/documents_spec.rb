require "rails_helper"

RSpec.describe "Repository documents", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before { sign_in_as(user) }

  def upload(filename:, content_type:, content: "hello")
    Rack::Test::UploadedFile.new(
      StringIO.new(content),
      content_type,
      original_filename: filename
    )
  end

  describe "GET /repositories/:repository_id/documents" do
    it "renders the documentation frame empty state and forms" do
      get repository_documents_path(repo, frame: 1)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("repository_#{repo.id}_documents")
      expect(response.body).to include("No supporting documents yet. Upload a file or link a Google Doc to give the agent extra context.")
      expect(response.body).to include("Upload a file")
      expect(response.body).to include("Link a Google Doc")
    end

    it "lists repository documents with metadata" do
      repo.repository_documents.create!(
        user: user,
        kind: "google_doc",
        title: "Launch plan",
        google_docs_url: "https://docs.google.com/document/d/launch/edit"
      )
      repo.repository_documents.create!(
        user: user,
        kind: "file",
        title: "Architecture",
        file: upload(filename: "architecture.pdf", content_type: "application/pdf", content: "%PDF")
      )

      get repository_documents_path(repo, frame: 1)

      expect(response.body).to include("Launch plan")
      expect(response.body).to include("https://docs.google.com/document/d/launch/edit")
      expect(response.body).to include("Architecture")
      expect(response.body).to include("architecture.pdf")
      expect(response.body).to include(user.display_name)
      expect(response.body).to include("Delete")
    end
  end

  describe "POST /repositories/:repository_id/documents" do
    it "creates a file document for the signed-in user's repository" do
      expect {
        post repository_documents_path(repo, frame: 1), params: {
          repository_document: {
            kind: "file",
            title: "API Notes",
            file: upload(filename: "api.md", content_type: "text/markdown", content: "# API")
          }
        }
      }.to change(Document, :count).by(1)

      document = repo.repository_documents.last
      expect(document.user).to eq(user)
      expect(document.title).to eq("API Notes")
      expect(document.file).to be_attached
      expect(response).to redirect_to(repository_documents_path(repo, frame: "1"))
    end

    it "creates a Google Docs link document" do
      expect {
        post repository_documents_path(repo, frame: 1), params: {
          repository_document: {
            kind: "google_doc",
            title: "Design brief",
            google_docs_url: "https://docs.google.com/document/d/design/edit"
          }
        }
      }.to change(Document, :count).by(1)

      document = repo.repository_documents.last
      expect(document.kind).to eq("google_doc")
      expect(document.google_docs_url).to eq("https://docs.google.com/document/d/design/edit")
      expect(document.file).not_to be_attached
    end

    it "rerenders validation errors for unsupported uploads" do
      expect {
        post repository_documents_path(repo, frame: 1), params: {
          repository_document: {
            kind: "file",
            title: "Archive",
            file: upload(filename: "archive.zip", content_type: "application/zip")
          }
        }
      }.not_to change(Document, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("must be a supported text, PDF, Office, or image file")
    end

    it "blocks access to another user's repository" do
      other_repo = Factories.repository(user: Factories.user, owner: "other", name: "private")

      post repository_documents_path(other_repo, frame: 1), params: {
        repository_document: {
          kind: "google_doc",
          title: "Private",
          google_docs_url: "https://docs.google.com/document/d/private/edit"
        }
      }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /documents/:id" do
    it "destroys the document and purges its attachment" do
      document = repo.repository_documents.create!(
        user: user,
        kind: "file",
        title: "Screenshot",
        file: upload(filename: "screen.png", content_type: "image/png", content: "png")
      )
      blob = document.file.blob

      expect {
        delete document_path(document, frame: 1)
      }.to change(Document, :count).by(-1)

      expect(ActiveStorage::Blob.where(id: blob.id)).to be_empty
      expect(response).to redirect_to(repository_documents_path(repo, frame: "1"))
    end

    it "blocks deletion of another user's document" do
      other = Factories.user
      other_repo = Factories.repository(user: other, owner: "other", name: "private")
      document = other_repo.repository_documents.create!(
        user: other,
        kind: "google_doc",
        title: "Private",
        google_docs_url: "https://docs.google.com/document/d/private/edit"
      )

      delete document_path(document, frame: 1)

      expect(response).to have_http_status(:not_found)
      expect(document.reload).to be_present
    end
  end
end
