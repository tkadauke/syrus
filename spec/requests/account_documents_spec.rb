require "rails_helper"

RSpec.describe "Account documents", type: :request do
  let(:user) { Factories.user }

  before { sign_in_as(user) }

  def upload_file(name: "notes.txt", content_type: "text/plain", content: "notes")
    file = Tempfile.new([ "document", File.extname(name) ])
    file.binmode
    file.write(content)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, content_type, original_filename: name)
  end

  it "uploads and deletes a user-scoped file document" do
    expect {
      post account_documents_path, params: {
        document: { files: [ upload_file ] }
      }
    }.to change(Document, :count).by(1)

    document = user.documents.last
    expect(document.attachable).to eq(user)
    expect(document.file).to be_attached
    expect(response).to redirect_to(edit_credentials_path)

    expect {
      delete account_document_path(document)
    }.to change(Document, :count).by(-1)
    expect(response).to redirect_to(edit_credentials_path)
  end

  it "adds a user-scoped Google Doc link" do
    post account_documents_path, params: {
      document: { google_doc_url: "https://docs.google.com/document/d/user/edit" }
    }

    document = user.documents.last
    expect(document).to be_google_doc
    expect(document.google_doc_url).to eq("https://docs.google.com/document/d/user/edit")
  end

  it "renders user documents on the credentials page" do
    user.documents.create!(
      kind: "google_doc",
      google_doc_url: "https://docs.google.com/document/d/user/edit",
      user: user
    )

    get edit_credentials_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Personal documents")
    expect(response.body).to include("https://docs.google.com/document/d/user/edit")
  end
end
