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
