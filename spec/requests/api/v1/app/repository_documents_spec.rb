require "rails_helper"

RSpec.describe "API: /api/v1/app/repository_documents", type: :request do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def parse_body
    JSON.parse(response.body)
  end

  def upload_file(name: "notes.md", content_type: "text/markdown", content: "# Notes")
    file = Tempfile.new([ "document", File.extname(name) ])
    file.binmode
    file.write(content)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, content_type, original_filename: name)
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/repositories/#{repository.id}/documents"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "lists repository documents for the signed-in user" do
    sign_in_as(user)
    repository.repository_documents.create!(
      user: user,
      kind: "google_doc",
      title: "Launch plan",
      google_docs_url: "https://docs.google.com/document/d/launch/edit"
    )

    get "/api/v1/app/repositories/#{repository.id}/documents"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.dig("repository", "slug")).to eq("acme/widgets")
    expect(body["tabs"].map { |t| t["key"] }).to include("overview", "github_issues", "documents", "scheduled_tasks")
    expect(body["tabs"].map { |t| t["key"] }).not_to include("context")
    expect(body["documents"]).to contain_exactly(
      include(
        "kind" => "google_doc",
        "title" => "Launch plan",
        "google_doc_url" => "https://docs.google.com/document/d/launch/edit",
        "uploaded_by" => user.display_name
      )
    )
    expect(body["accepted_file_content_types"]).to include("application/pdf")
  end

  it "includes the insights tab when agent insights is enabled" do
    Feature.find_or_create_by!(slug: "agent_insights") { |f|
      f.category = "Labs"; f.name = "Agent Insights"
    }.update!(enabled: true)
    sign_in_as(user)

    get "/api/v1/app/repositories/#{repository.id}/documents"

    tab_keys = JSON.parse(response.body)["tabs"].map { |t| t["key"] }
    expect(tab_keys).to include("insights")
  end

  it "excludes the insights tab when agent insights is disabled" do
    Feature.find_or_create_by!(slug: "agent_insights") { |f|
      f.category = "Labs"; f.name = "Agent Insights"
    }.update!(enabled: false)
    sign_in_as(user)

    get "/api/v1/app/repositories/#{repository.id}/documents"

    tab_keys = JSON.parse(response.body)["tabs"].map { |t| t["key"] }
    expect(tab_keys).not_to include("insights")
  end

  it "creates a file document" do
    sign_in_as(user)

    expect {
      post "/api/v1/app/repositories/#{repository.id}/documents", params: {
        repository_document: {
          kind: "file",
          title: "API notes",
          file: upload_file
        }
      }
    }.to change(Document, :count).by(1)

    expect(response).to have_http_status(:created)
    document = repository.repository_documents.last
    expect(document.user).to eq(user)
    expect(document.title).to eq("API notes")
    expect(document.file).to be_attached
    expect(parse_body["message"]).to eq("Document added.")
    expect(parse_body["documents"].first).to include("filename" => "notes.md")
  end

  it "creates a Google Docs link document" do
    sign_in_as(user)

    expect {
      post "/api/v1/app/repositories/#{repository.id}/documents", params: {
        repository_document: {
          kind: "google_doc",
          title: "Design brief",
          google_docs_url: "https://docs.google.com/document/d/design/edit"
        }
      }
    }.to change(Document, :count).by(1)

    expect(response).to have_http_status(:created)
    expect(repository.repository_documents.last.google_docs_url).to eq("https://docs.google.com/document/d/design/edit")
    expect(parse_body.dig("documents", 0, "title")).to eq("Design brief")
  end

  it "returns validation errors" do
    sign_in_as(user)

    expect {
      post "/api/v1/app/repositories/#{repository.id}/documents", params: {
        repository_document: {
          kind: "file",
          title: "Archive",
          file: upload_file(name: "archive.zip", content_type: "application/zip")
        }
      }
    }.not_to change(Document, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
    expect(parse_body.dig("error", "message")).to include("supported text, PDF, Office, or image file")
  end

  it "deletes repository documents" do
    sign_in_as(user)
    document = repository.repository_documents.create!(
      user: user,
      kind: "file",
      title: "Screenshot",
      file: upload_file(name: "screen.png", content_type: "image/png", content: "png")
    )
    blob = document.file.blob

    expect {
      delete "/api/v1/app/repository_documents/#{document.id}"
    }.to change(Document, :count).by(-1)

    expect(response).to have_http_status(:ok)
    expect(ActiveStorage::Blob.where(id: blob.id)).to be_empty
    expect(parse_body["message"]).to eq("Document removed.")
  end

  it "does not expose another user's repository or documents" do
    sign_in_as(user)
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user, owner: "other", name: "private")
    document = other_repo.repository_documents.create!(
      user: other_user,
      kind: "google_doc",
      title: "Private",
      google_docs_url: "https://docs.google.com/document/d/private/edit"
    )

    get "/api/v1/app/repositories/#{other_repo.id}/documents"
    expect(response).to have_http_status(:not_found)

    delete "/api/v1/app/repository_documents/#{document.id}"
    expect(response).to have_http_status(:not_found)
    expect(document.reload).to be_present
  end
end
