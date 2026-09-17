require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/retention_archives", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:non_admin) { Factories.user }

  # Real archivable RetentionPolicyRegistry entry so the payload/download
  # paths exercise a real key without asserting on the full
  # (plugin-extendable) registry list core specs must not enumerate.
  let(:archivable_definition) { RetentionPolicyRegistry.fetch(:run_diagnostic) }
  let(:non_archivable_definition) { RetentionPolicyRegistry.fetch(:notification) }

  def parse_body
    JSON.parse(response.body)
  end

  def upload(filename: "archive.jsonl.gz")
    Rack::Test::UploadedFile.new(
      StringIO.new("archived-rows"),
      "application/gzip",
      original_filename: filename
    )
  end

  def create_archive(overrides = {})
    skip_attach = overrides.delete(:skip_attach)
    archive = RetentionArchive.create!({
      retention_key: archivable_definition.key.to_s,
      pruned_before: 30.days.ago,
      row_count: 42,
      byte_size: 1024
    }.merge(overrides))
    archive.archive_file.attach(upload) unless skip_attach
    archive
  end

  before do
    allow(RetentionPolicyRegistry).to receive(:definitions).and_return([ archivable_definition, non_archivable_definition ])
  end

  describe "GET index" do
    it "401s with a JSON error when signed out" do
      get "/api/v1/app/admin/retention_archives", params: { retention_key: archivable_definition.key }

      expect(response).to have_http_status(:unauthorized)
      expect(parse_body.dig("error", "code")).to eq("unauthorized")
    end

    it "403s with a JSON error for non-admin users" do
      sign_in_as(non_admin)

      get "/api/v1/app/admin/retention_archives", params: { retention_key: archivable_definition.key }

      expect(response).to have_http_status(:forbidden)
      expect(parse_body.dig("error", "code")).to eq("forbidden")
    end

    it "lists archives for the given retention key, newest first, with a download link" do
      sign_in_as(admin)
      older = create_archive(pruned_before: 60.days.ago, row_count: 10, byte_size: 100)
      newer = create_archive(pruned_before: 1.day.ago, row_count: 20, byte_size: 200)

      get "/api/v1/app/admin/retention_archives", params: { retention_key: archivable_definition.key }

      expect(response).to have_http_status(:ok)
      expect(parse_body["retention_key"]).to eq(archivable_definition.key.to_s)
      rows = parse_body["archives"]
      expect(rows.map { |row| row["id"] }).to eq([ newer.id, older.id ])
      expect(rows.first).to include(
        "row_count" => 20,
        "byte_size" => 200,
        "filename" => newer.archive_file.filename.to_s
      )
      expect(rows.first["download_path"]).to eq("/api/v1/app/admin/retention_archives/#{newer.id}/download")
    end

    it "does not include archives from other retention keys" do
      sign_in_as(admin)
      create_archive
      other = RetentionArchive.create!(
        retention_key: "notification",
        pruned_before: 1.day.ago,
        row_count: 5,
        byte_size: 50
      )

      get "/api/v1/app/admin/retention_archives", params: { retention_key: archivable_definition.key }

      expect(parse_body["archives"].map { |row| row["id"] }).not_to include(other.id)
    end

    it "paginates results" do
      sign_in_as(admin)
      27.times { |i| create_archive(pruned_before: (i + 1).days.ago) }

      get "/api/v1/app/admin/retention_archives", params: { retention_key: archivable_definition.key }

      expect(parse_body["archives"].length).to eq(20)
      expect(parse_body["pagination"]).to include("page" => 1, "per_page" => 20, "total" => 27, "total_pages" => 2)

      get "/api/v1/app/admin/retention_archives", params: { retention_key: archivable_definition.key, page: 2 }

      expect(parse_body["archives"].length).to eq(7)
    end

    it "404s for an unknown retention key" do
      sign_in_as(admin)

      get "/api/v1/app/admin/retention_archives", params: { retention_key: "not_a_real_key" }

      expect(response).to have_http_status(:not_found)
    end

    it "404s for a non-archivable retention key" do
      sign_in_as(admin)

      get "/api/v1/app/admin/retention_archives", params: { retention_key: non_archivable_definition.key }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET download" do
    it "401s with a JSON error when signed out" do
      archive = create_archive

      get "/api/v1/app/admin/retention_archives/#{archive.id}/download"

      expect(response).to have_http_status(:unauthorized)
    end

    it "403s for non-admin users" do
      sign_in_as(non_admin)
      archive = create_archive

      get "/api/v1/app/admin/retention_archives/#{archive.id}/download"

      expect(response).to have_http_status(:forbidden)
    end

    it "redirects to the attached archive file's native Active Storage blob URL for an admin" do
      sign_in_as(admin)
      archive = create_archive

      get "/api/v1/app/admin/retention_archives/#{archive.id}/download"

      expect(response).to have_http_status(:redirect)
      expect(response.location).to include(rails_blob_path(archive.archive_file, disposition: "attachment"))
    end

    it "404s when the archive has no attached file" do
      sign_in_as(admin)
      archive = create_archive(skip_attach: true)

      get "/api/v1/app/admin/retention_archives/#{archive.id}/download"

      expect(response).to have_http_status(:not_found)
    end

    it "404s for an unknown archive id" do
      sign_in_as(admin)

      get "/api/v1/app/admin/retention_archives/999999/download"

      expect(response).to have_http_status(:not_found)
    end
  end
end
