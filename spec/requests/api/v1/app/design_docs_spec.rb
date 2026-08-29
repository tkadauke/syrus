require "rails_helper"

RSpec.describe "API: /api/v1/app/design_docs", type: :request do
  let(:owner) { Factories.user(email_address: "owner@example.com") }
  let(:collaborator) { Factories.user(email_address: "collaborator@example.com") }
  let(:outsider) { Factories.user(email_address: "outsider@example.com") }
  let(:repository) { Factories.repository(user: owner, owner: "acme", name: "widgets") }

  def parse_body
    JSON.parse(response.body)
  end

  def create_design_doc(**attrs)
    doc = DesignDoc.create!({
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

  it "creates a design doc with DOC identity, initial version, repositories, collaborators, and origin chat" do
    chat = ChatSession.create!(user: owner, title: "Design chat")
    repository.repository_memberships.create!(user: collaborator, role: "read")
    sign_in_as(owner)

    expect {
      post "/api/v1/app/design_docs", params: {
        design_doc: {
          title: " Design Brief ",
          markdown: "# Brief",
          visibility: "public",
          repository_ids: [ repository.id ],
          collaborator_user_ids: [ collaborator.id ],
          origin_chat_session_id: chat.id
        }
      }
    }.to change(DesignDoc, :count).by(1)
      .and change(DesignDocVersion, :count).by(1)

    expect(response).to have_http_status(:created)
    doc = DesignDoc.last
    body = parse_body.fetch("design_doc")
    expect(body).to include(
      "id" => doc.id,
      "display_id" => "DOC-#{doc.id}",
      "title" => "Design Brief",
      "markdown" => "# Brief",
      "visibility" => "public",
      "origin_chat_session_id" => chat.id,
      "current_version_number" => 1
    )
    expect(body.fetch("repository_ids")).to eq([ repository.id ])
    expect(body.fetch("collaborator_ids")).to eq([ collaborator.id ])
    expect(doc.current_version.markdown).to eq("# Brief")
  end

  it "lists docs visible through ownership, collaboration, and public repository access" do
    private_collab = create_design_doc(title: "Private shared")
    private_collab.collaborators.create!(user: collaborator, role: "editor", added_by_user: owner)
    public_doc = create_design_doc(title: "Public linked", visibility: "public")
    public_doc.repositories << repository
    create_design_doc(title: "Owner only")
    repository.repository_memberships.create!(user: collaborator, role: "read")
    sign_in_as(collaborator)

    get "/api/v1/app/design_docs"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("design_docs").map { |doc| doc.fetch("title") }).to contain_exactly("Public linked", "Private shared")
  end

  it "lists visible docs scoped to a repository" do
    public_doc = create_design_doc(title: "Repository plan", visibility: "public")
    public_doc.repositories << repository
    create_design_doc(title: "Unlinked public", visibility: "public")
    repository.repository_memberships.create!(user: collaborator, role: "read")
    sign_in_as(collaborator)

    get "/api/v1/app/repositories/#{repository.id}/design_docs"

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("repository", "slug")).to eq("acme/widgets")
    expect(parse_body.fetch("design_docs").map { |doc| doc.fetch("title") }).to eq([ "Repository plan" ])
  end

  it "denies private docs to users who are neither owners nor collaborators" do
    doc = create_design_doc
    sign_in_as(outsider)

    get "/api/v1/app/design_docs/#{doc.id}"

    expect(response).to have_http_status(:not_found)
  end

  it "lets owners update canonical markdown and creates a new append-only version" do
    doc = create_design_doc(markdown: "v1")
    sign_in_as(owner)

    expect {
      patch "/api/v1/app/design_docs/#{doc.id}", params: {
        design_doc: {
          markdown: "v2",
          change_summary: "Revise body"
        }
      }
    }.to change(DesignDocVersion, :count).by(1)
      .and change(DesignDocSuggestion, :count).by(0)

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("mode")).to eq("canonical")
    expect(parse_body.dig("version", "version_number")).to eq(2)
    expect(doc.reload.markdown).to eq("v2")
    expect(doc.current_version.markdown).to eq("v2")
    expect(doc.versions.order(:version_number).pluck(:markdown)).to eq(%w[v1 v2])
  end

  it "turns collaborator markdown edits into suggestions without mutating canonical markdown" do
    doc = create_design_doc(markdown: "Hello world")
    doc.collaborators.create!(user: collaborator, role: "editor", added_by_user: owner)
    sign_in_as(collaborator)

    expect {
      patch "/api/v1/app/design_docs/#{doc.id}", params: {
        design_doc: {
          markdown: "Hello Syrus",
          start_offset: 6,
          end_offset: 11,
          selected_markdown: "world",
          change_summary: "Use product name"
        }
      }
    }.to change(DesignDocSuggestion, :count).by(1)
      .and change(DesignDocVersion, :count).by(0)

    expect(response).to have_http_status(:ok)
    suggestion = DesignDocSuggestion.last
    expect(parse_body.fetch("mode")).to eq("suggestion")
    expect(parse_body.dig("suggestion", "id")).to eq(suggestion.id)
    expect(parse_body.dig("suggestion", "anchor")).to include(
      "start_offset" => 6,
      "end_offset" => 11,
      "selected_markdown" => "world"
    )
    expect(suggestion).to have_attributes(
      suggested_by_kind: "user",
      suggested_by_user: collaborator,
      original_markdown: "world",
      suggested_markdown: "Hello Syrus"
    )
    expect(doc.reload.markdown).to eq("Hello world")
  end

  it "enforces agent write restrictions even when the owner is the authenticated user" do
    doc = create_design_doc(markdown: "canonical")
    sign_in_as(owner)

    expect {
      patch "/api/v1/app/design_docs/#{doc.id}", params: {
        actor_kind: "agent",
        design_doc: {
          markdown: "agent rewrite",
          change_summary: "Agent proposal"
        }
      }
    }.to change(DesignDocSuggestion, :count).by(1)
      .and change(DesignDocVersion, :count).by(0)

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("mode")).to eq("suggestion")
    expect(DesignDocSuggestion.last.suggested_by_kind).to eq("agent")
    expect(doc.reload.markdown).to eq("canonical")
  end

  it "returns version history newest first" do
    doc = create_design_doc(markdown: "v1")
    doc.versions.create!(markdown: "v2", version_number: 2, actor_kind: "user", actor_user: owner)
    sign_in_as(owner)

    get "/api/v1/app/design_docs/#{doc.id}/versions"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("versions").map { |version| version.fetch("version_number") }).to eq([ 2, 1 ])
    expect(parse_body.fetch("design_doc")).to include("display_id" => "DOC-#{doc.id}")
  end
end
