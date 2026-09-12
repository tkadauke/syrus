require "rails_helper"

RSpec.describe "App API Design Docs global search", type: :request do
  let(:owner) { Factories.user(email_address: "owner@example.com") }
  let(:repository) { Factories.repository(user: owner, owner: "acme", name: "widgets") }

  before do
    allow(AppEvents).to receive(:broadcast)
    prepare_search_table
    sign_in_as(owner)
  end

  it "returns an exact DOC lookup before body matches" do
    exact = create_design_doc(title: "Runtime plan", markdown: "ordinary", repository: repository)
    body_match = create_design_doc(title: "Other plan", markdown: "mentions #{exact.display_id}", repository: repository)
    [ body_match, exact ].each { |doc| DesignDocs::SearchIndex.upsert(doc.reload) }

    get "/api/v1/app/search", params: { query: exact.display_id, types: [ "design_doc" ] }

    expect(response).to have_http_status(:ok)
    expect(results.first).to include(
      "type" => "design_doc",
      "id" => exact.id,
      "slug" => exact.display_id,
      "title" => "Runtime plan",
      "snippet" => "<mark>#{exact.display_id}</mark>",
      "path" => "/design_docs/#{exact.id}",
      "repository_slug" => "acme/widgets",
      "visibility" => "private"
    )
  end

  it "finds title and body text" do
    title_match = create_design_doc(title: "Target Graphs", markdown: "body", repository: repository)
    body_match = create_design_doc(title: "Runtime", markdown: "Target graph details", repository: repository)
    [ title_match, body_match ].each { |doc| DesignDocs::SearchIndex.upsert(doc.reload) }

    get "/api/v1/app/search", params: { query: "Target", types: [ "design_doc" ] }

    expect(response).to have_http_status(:ok)
    expect(results.map { |row| row.fetch("id") }).to match_array([ title_match.id, body_match.id ])
  end

  it "does not leak private docs to non-collaborators" do
    private_doc = create_design_doc(title: "Secret Runtime", markdown: "launch codes", repository: repository)
    collaborator_doc = create_design_doc(title: "Shared Runtime", markdown: "launch codes", repository: repository)
    viewer = Factories.user
    collaborator_doc.collaborators.create!(user: viewer, role: "viewer", added_by_user: owner)
    [ private_doc, collaborator_doc ].each { |doc| DesignDocs::SearchIndex.upsert(doc.reload) }

    sign_in_as(viewer)
    get "/api/v1/app/search", params: { query: "launch", types: [ "design_doc" ] }

    expect(response).to have_http_status(:ok)
    expect(results).to contain_exactly(include("id" => collaborator_doc.id, "title" => "Shared Runtime"))
  end

  it "shows public docs only through accessible repositories" do
    member = Factories.user
    outsider = Factories.user
    repository.repository_memberships.create!(user: member, role: "read")
    doc = create_design_doc(title: "Public Runtime", markdown: "public launch", visibility: "public", repository: repository)
    DesignDocs::SearchIndex.upsert(doc.reload)

    sign_in_as(member)
    get "/api/v1/app/search", params: { query: "launch", types: [ "design_doc" ] }
    expect(results).to contain_exactly(include("id" => doc.id))

    sign_in_as(outsider)
    get "/api/v1/app/search", params: { query: "launch", types: [ "design_doc" ] }
    expect(results).to eq([])
  end

  it "rejects the design_doc type when design_docs is disabled" do
    PluginRecord.find_or_create_by!(name: "design_docs").update!(enabled: false, disableable: true)

    get "/api/v1/app/search", params: { query: "runtime", types: [ "design_doc" ] }

    expect(response).to have_http_status(:bad_request)
  end

  def create_design_doc(title:, markdown:, visibility: "private", repository: nil)
    doc = DesignDocs::DesignDoc.create!(owner_user: owner, title: title, markdown: markdown, visibility: visibility)
    doc.repositories << repository if repository
    doc
  end

  def results
    JSON.parse(response.body).fetch("results")
  end

  def prepare_search_table
    SearchRecord.connection.execute("DROP TABLE IF EXISTS design_doc_fts")
    SearchRecord.connection.execute(DesignDocs::SearchSource::TABLE_SQL)
  end
end
