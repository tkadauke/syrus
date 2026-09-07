require "rails_helper"

RSpec.describe "API: /api/v1/admin/design_docs", type: :request do
  let!(:admin) { Factories.user(email_address: "admin@example.com", admin: true) }
  let!(:non_admin) { Factories.user(email_address: "non-admin@example.com", admin: false) }
  let(:admin_token) { admin.generate_api_token! }
  let(:non_admin_token) { non_admin.generate_api_token! }

  def auth(token = admin_token) = { "Authorization" => "Bearer #{token}" }
  def parse_body = JSON.parse(response.body)

  before do
    DesignDocs.register! unless PluginRecord.exists?(name: "design_docs")
    PluginRecord.find_by!(name: "design_docs").update!(enabled: true)
  end

  def create_design_doc(owner: admin, **attrs)
    doc = DesignDocs::DesignDoc.create!({
      owner_user: owner,
      title: "Checkout design",
      markdown: "# Checkout",
      visibility: "private"
    }.merge(attrs))
    version = doc.versions.create!(
      markdown: doc.markdown,
      version_number: 1,
      actor_kind: "user",
      actor_user: owner
    )
    doc.update!(current_version: version)
    doc
  end

  it "401s without a token" do
    get "/api/v1/admin/design_docs"

    expect(response).to have_http_status(:unauthorized)
  end

  it "403s for non-admin API tokens" do
    get "/api/v1/admin/design_docs", headers: auth(non_admin_token)

    expect(response).to have_http_status(:forbidden)
  end

  it "404s with plugin_disabled when the design_docs plugin is disabled" do
    PluginRecord.find_by!(name: "design_docs").update!(enabled: false)

    get "/api/v1/admin/design_docs", headers: auth

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("plugin_disabled")
  end

  describe "GET /index" do
    it "lists design docs across owners, filterable by state, visibility, and user" do
      draft = create_design_doc(title: "Draft doc", state: "draft")
      accepted = create_design_doc(title: "Accepted doc", state: "accepted", visibility: "public")
      other_owner = create_design_doc(title: "Other owner doc", owner: non_admin)

      get "/api/v1/admin/design_docs", headers: auth

      expect(response).to have_http_status(:ok)
      titles = parse_body.fetch("design_docs").map { |doc| doc.fetch("title") }
      expect(titles).to contain_exactly("Draft doc", "Accepted doc", "Other owner doc")

      get "/api/v1/admin/design_docs", params: { state: "accepted" }, headers: auth
      expect(parse_body.fetch("design_docs").map { |doc| doc.fetch("id") }).to eq([ accepted.id ])

      get "/api/v1/admin/design_docs", params: { visibility: "public" }, headers: auth
      expect(parse_body.fetch("design_docs").map { |doc| doc.fetch("id") }).to eq([ accepted.id ])

      get "/api/v1/admin/design_docs", params: { user: "non-admin" }, headers: auth
      expect(parse_body.fetch("design_docs").map { |doc| doc.fetch("id") }).to eq([ other_owner.id ])

      expect(draft).to be_present
    end
  end

  describe "POST /create" do
    it "creates a design doc owned by the API token's user, with an initial version" do
      expect {
        post "/api/v1/admin/design_docs",
             params: { design_doc: { title: " Ops Runbook ", markdown: "# Runbook" } },
             headers: auth
      }.to change(DesignDocs::DesignDoc, :count).by(1)
        .and change(DesignDocs::DesignDocVersion, :count).by(1)

      expect(response).to have_http_status(:created)
      doc = DesignDocs::DesignDoc.last
      body = parse_body.fetch("design_doc")
      expect(body).to include(
        "id" => doc.id,
        "display_id" => "DOC-#{doc.id}",
        "title" => "Ops Runbook",
        "markdown" => "# Runbook",
        "current_version_number" => 1
      )
      expect(doc.owner_user).to eq(admin)
    end

    it "accepts a flat (non-nested) body" do
      post "/api/v1/admin/design_docs",
           params: { title: "Flat body doc", markdown: "# Flat" },
           headers: auth

      expect(response).to have_http_status(:created)
      expect(parse_body.dig("design_doc", "title")).to eq("Flat body doc")
    end

    it "returns validation_failed for a blank title" do
      post "/api/v1/admin/design_docs",
           params: { design_doc: { title: "", markdown: "# Body" } },
           headers: auth

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("validation_failed")
    end
  end

  describe "GET /show" do
    it "returns detail including current markdown" do
      doc = create_design_doc

      get "/api/v1/admin/design_docs/#{doc.id}", headers: auth

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("design_doc", "markdown")).to eq("# Checkout")
    end

    it "404s for a missing design doc" do
      get "/api/v1/admin/design_docs/999999", headers: auth

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /update" do
    it "updates title/markdown/state and records a version, same as the app path" do
      doc = create_design_doc

      expect {
        patch "/api/v1/admin/design_docs/#{doc.id}",
              params: { design_doc: { title: "Renamed", markdown: "# Renamed body", state: "accepted" } },
              headers: auth
      }.to change { doc.versions.count }.by(1)

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("design_doc", "title")).to eq("Renamed")
      expect(body.dig("design_doc", "markdown")).to eq("# Renamed body")
      expect(body.dig("design_doc", "state")).to eq("accepted")
      expect(body["version"]).to be_present
      expect(body.dig("version", "version_number")).to eq(2)
      expect(doc.reload.current_version.version_number).to eq(2)
    end

    it "returns validation_failed for an invalid state" do
      doc = create_design_doc

      patch "/api/v1/admin/design_docs/#{doc.id}",
            params: { design_doc: { state: "bogus" } },
            headers: auth

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("validation_failed")
    end
  end

  describe "GET /versions" do
    it "returns version history" do
      doc = create_design_doc
      patch "/api/v1/admin/design_docs/#{doc.id}",
            params: { design_doc: { markdown: "# Second" } },
            headers: auth

      get "/api/v1/admin/design_docs/#{doc.id}/versions", headers: auth

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body.dig("design_doc", "id")).to eq(doc.id)
      version_numbers = body.fetch("versions").map { |version| version.fetch("version_number") }
      expect(version_numbers).to eq([ 2, 1 ])
    end
  end
end
