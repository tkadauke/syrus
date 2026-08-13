require "rails_helper"

RSpec.describe "App API job attachments", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(repository: repo, issue_number: 42) }

  before { sign_in_as(user) }

  def parse_body = JSON.parse(response.body)
  def app_attachments_path(job_record) = "/api/v1/app/jobs/#{job_record.id}/attachments"
  def app_attachment_path(job_record, attachment) = "/api/v1/app/jobs/#{job_record.id}/attachments/#{attachment.id}"
  def app_attachment_file_path(job_record, attachment) = "/api/v1/app/jobs/#{job_record.id}/attachments/#{attachment.id}/file"
  def app_attachment_content_path(job_record, attachment) = "/api/v1/app/jobs/#{job_record.id}/attachments/#{attachment.id}/content"

  def upload_file(name: "notes.md", content_type: "text/markdown", content: "# Notes")
    file = Tempfile.new([ "job-attachment", File.extname(name) ])
    file.binmode
    file.write(content)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, content_type, original_filename: name)
  end

  it "adds file and Google Doc attachments to one of the current user's jobs" do
    expect(AppEvents).to receive(:broadcast).with(
      user: user,
      type: "updated",
      resource: "job",
      id: job.id,
      changed: [ "attachments" ],
      payload: { "attachments_count" => 2 }
    )

    expect {
      post app_attachments_path(job),
           params: {
             job_attachment: {
               files: [ upload_file ],
               google_doc_url: "https://docs.google.com/document/d/context/edit"
             }
           }
    }.to change(Document, :count).by(2)

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["message"]).to eq("Attachments added.")
    expect(body.dig("job", "attachments_count")).to eq(2)
    expect(body["attachments"].map { |attachment| attachment["kind"] }).to contain_exactly("file", "google_doc")
    expect(body["attachments"]).to include(
      include(
        "filename" => "notes.md",
        "file_path" => %r{\A/api/v1/app/jobs/#{job.id}/attachments/\d+/file\z},
        "app_delete_path" => %r{\A/api/v1/app/jobs/#{job.id}/attachments/\d+\z}
      ),
      include("google_doc_url" => "https://docs.google.com/document/d/context/edit")
    )
    expect(body["attachments"].first).not_to have_key("delete_path")
  end

  it "serves uploaded attachment files through an authenticated app endpoint" do
    attachment = job.job_attachments.build(attachment_type: "uploaded_file")
    attachment.file.attach(
      io: StringIO.new("hello from storage"),
      filename: "notes.txt",
      content_type: "text/plain"
    )
    attachment.save!

    get app_attachment_file_path(job, attachment)

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/plain")
    expect(response.headers["Content-Disposition"]).to include("inline")
    expect(response.headers["Content-Disposition"]).to include("notes.txt")
    expect(response.body).to eq("hello from storage")
  end

  it "returns markdown attachment content as JSON for the shared file preview modal" do
    attachment = job.job_attachments.build(attachment_type: "uploaded_file")
    attachment.file.attach(
      io: StringIO.new("# Notes\n\nHello"),
      filename: "notes.md",
      content_type: "text/markdown"
    )
    attachment.save!

    get app_attachment_content_path(job, attachment)

    expect(response).to have_http_status(:ok)
    expect(parse_body).to eq(
      "path" => "notes.md",
      "content" => "# Notes\n\nHello",
      "binary" => false,
      "too_large" => false
    )
  end

  it "flags binary attachment content instead of inlining it" do
    attachment = job.job_attachments.build(attachment_type: "uploaded_file")
    attachment.file.attach(
      io: StringIO.new("\x89PNG\x00binary"),
      filename: "screenshot.png",
      content_type: "image/png"
    )
    attachment.save!

    get app_attachment_content_path(job, attachment)

    expect(response).to have_http_status(:ok)
    expect(parse_body).to eq("path" => "screenshot.png", "content" => nil, "binary" => true, "too_large" => false)
  end

  it "flags oversized attachment content instead of downloading it" do
    attachment = job.job_attachments.build(attachment_type: "uploaded_file")
    attachment.file.attach(
      io: StringIO.new("x" * (Document::MAX_PREVIEW_SIZE + 1)),
      filename: "huge.txt",
      content_type: "text/plain"
    )
    attachment.save!

    get app_attachment_content_path(job, attachment)

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body).to include("path" => "huge.txt", "content" => nil, "binary" => false, "too_large" => true)
    expect(body["size"]).to eq(Document::MAX_PREVIEW_SIZE + 1)
  end

  it "exposes a content_path for uploaded attachments and none for Google Doc links" do
    file_attachment = job.job_attachments.build(attachment_type: "uploaded_file")
    file_attachment.file.attach(io: StringIO.new("hello"), filename: "notes.txt", content_type: "text/plain")
    file_attachment.save!
    doc_attachment = job.job_attachments.create!(
      attachment_type: "google_doc_link",
      google_doc_url: "https://docs.google.com/document/d/context/edit"
    )

    get app_attachment_content_path(job, file_attachment)
    expect(response).to have_http_status(:ok)

    post app_attachments_path(job),
         params: { job_attachment: { google_doc_url: "https://docs.google.com/document/d/other/edit" } },
         as: :json
    attachments = parse_body["attachments"]
    expect(attachments.find { |a| a["id"] == file_attachment.id }["content_path"]).to eq(app_attachment_content_path(job, file_attachment))
    expect(attachments.find { |a| a["id"] == doc_attachment.id }["content_path"]).to be_nil
  end

  it "does not serve another user's attachment content" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user, owner: "globex", name: "private")
    other_job = Factories.job_record(repository: other_repo, issue_number: 99)
    attachment = other_job.job_attachments.build(attachment_type: "uploaded_file")
    attachment.file.attach(io: StringIO.new("secret"), filename: "secret.txt", content_type: "text/plain")
    attachment.save!

    get app_attachment_content_path(other_job, attachment)

    expect(response).to have_http_status(:not_found)
  end

  it "rejects empty attachment submissions" do
    expect(AppEvents).not_to receive(:broadcast)

    expect {
      post app_attachments_path(job), params: { job_attachment: {} }, as: :json
    }.not_to change(Document, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body).to eq(
      "error" => {
        "code" => "validation_failed",
        "message" => "Choose a file or enter a Google Doc URL."
      }
    )
  end

  it "removes one of the current user's job attachments" do
    attachment = job.job_attachments.create!(
      attachment_type: "google_doc_link",
      google_doc_url: "https://docs.google.com/document/d/context/edit"
    )
    expect(AppEvents).to receive(:broadcast).with(
      user: user,
      type: "updated",
      resource: "job",
      id: job.id,
      changed: [ "attachments" ],
      payload: { "attachments_count" => 0 }
    )

    expect {
      delete app_attachment_path(job, attachment), as: :json
    }.to change(Document, :count).by(-1)

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include(
      "message" => "Attachment removed.",
      "attachments" => [],
      "job" => include("attachments_count" => 0)
    )
  end

  it "does not expose another user's job" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user, owner: "globex", name: "private")
    other_job = Factories.job_record(repository: other_repo, issue_number: 99)

    post app_attachments_path(other_job),
         params: { job_attachment: { google_doc_url: "https://docs.google.com/document/d/context/edit" } },
         as: :json

    expect(response).to have_http_status(:not_found)
    expect(job.job_attachments).to be_empty
    expect(other_job.job_attachments).to be_empty
  end

  it "does not serve another user's attachment file" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user, owner: "globex", name: "private")
    other_job = Factories.job_record(repository: other_repo, issue_number: 99)
    attachment = other_job.job_attachments.build(attachment_type: "uploaded_file")
    attachment.file.attach(
      io: StringIO.new("secret"),
      filename: "secret.txt",
      content_type: "text/plain"
    )
    attachment.save!

    get app_attachment_file_path(other_job, attachment)

    expect(response).to have_http_status(:not_found)
  end
end
