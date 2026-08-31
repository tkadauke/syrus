require "rails_helper"

RSpec.describe "API: /api/v1/app/design_docs", type: :request do
  let(:owner) { Factories.user(email_address: "owner@example.com") }
  let(:collaborator) { Factories.user(email_address: "collaborator@example.com") }
  let(:outsider) { Factories.user(email_address: "outsider@example.com") }
  let(:repository) { Factories.repository(user: owner, owner: "acme", name: "widgets") }

  def parse_body
    JSON.parse(response.body)
  end

  def capture_sql
    queries = []
    callback = ->(_name, _started, _finished, _id, payload) do
      next if payload[:name] == "SCHEMA"

      queries << payload[:sql]
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
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

  it "returns not found when the design_docs plugin is disabled" do
    PluginRecord.find_by!(name: "design_docs").update!(enabled: false)
    sign_in_as(owner)

    get "/api/v1/app/design_docs"

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("plugin_disabled")
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
    expect(parse_body.fetch("filter_schema").map { |field| field.fetch("field") }).to include("repository_id", "owner_user_id", "state", "visibility", "title", "content", "created_at", "updated_at")
    expect(parse_body.fetch("smart_folders").map { |folder| folder.fetch("name") }).to include("My docs", "Recently updated")
  end

  it "does not render duplicate built-in smart folders when stale duplicates exist" do
    cache_store = ActiveSupport::Cache::MemoryStore.new
    allow(Rails).to receive(:cache).and_return(cache_store)
    create_design_doc(title: "Owner only")
    sign_in_as(owner)

    SmartFolder.ensure_builtins_for_subject!("design_doc")
    my_docs = SmartFolder.builtins(:design_doc).find_by!(name: "My docs")
    SmartFolder.insert_all!([
      {
        name: my_docs.name,
        kind: my_docs.kind,
        subject_type: my_docs.subject_type,
        filter: my_docs.filter,
        position: my_docs.position + 1,
        user_id: nil,
        created_at: Time.current,
        updated_at: Time.current
      }
    ])

    get "/api/v1/app/design_docs"

    expect(response).to have_http_status(:ok)
    folder_names = parse_body.fetch("smart_folders").map { |folder| folder.fetch("name") }
    expect(folder_names.count("My docs")).to eq(1)
  end

  it "filters design docs by content through the shared FilterBar AST" do
    matching = create_design_doc(title: "Matching", markdown: "Operational queue health")
    create_design_doc(title: "Other", markdown: "Release notes")
    sign_in_as(owner)

    q = Base64.urlsafe_encode64(
      JSON.generate("and" => [ { "field" => "content", "op" => "matches", "value" => "queue health" } ]),
      padding: false
    )
    get "/api/v1/app/design_docs", params: { q: q }

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("design_docs").map { |doc| doc.fetch("id") }).to eq([ matching.id ])
  end

  it "filters design docs from a smart folder and routes saved folders back to Design Docs" do
    own_doc = create_design_doc(title: "Owned draft")
    public_doc = create_design_doc(title: "Accepted public", visibility: "public", state: "accepted")
    public_doc.repositories << repository
    repository.repository_memberships.create!(user: collaborator, role: "read")
    sign_in_as(collaborator)

    post "/api/v1/app/smart_folders", params: {
      subject_type: "design_doc",
      filter: { and: [ { field: "state", op: "is", value: "accepted" } ] }.to_json,
      smart_folder: { name: "Accepted docs" }
    }

    expect(response).to have_http_status(:created)
    folder = collaborator.smart_folders.find_by!(name: "Accepted docs")
    expect(parse_body.fetch("redirect_to")).to eq("/design_docs?smart_folder_id=#{folder.id}")

    get "/api/v1/app/design_docs", params: { smart_folder_id: folder.id }

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("active_smart_folder_id")).to eq(folder.id)
    expect(parse_body.fetch("design_docs").map { |doc| doc.fetch("title") }).to eq([ "Accepted public" ])
    expect(parse_body.fetch("design_docs").map { |doc| doc.fetch("title") }).not_to include(own_doc.title)
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
      .and change(DesignDocVersion, :count).by(1)

    expect(response).to have_http_status(:ok)
    suggestion = DesignDocSuggestion.last
    expect(parse_body.fetch("mode")).to eq("suggestion")
    expect(parse_body.dig("suggestion", "id")).to eq(suggestion.id)
    expect(parse_body.dig("suggestion", "anchor")).to include(
      "anchor_kind" => "range",
      "status" => "active",
      "start_offset" => 6,
      "end_offset" => 11,
      "selected_markdown" => "world",
      "selected_text" => "world"
    )
    expect(suggestion).to have_attributes(
      suggested_by_kind: "user",
      suggested_by_user: collaborator,
      original_markdown: "world",
      suggested_markdown: "Syrus",
      proposed_markdown: "Syrus"
    )
    expect(doc.reload.markdown).to include("<!-- syrus:range-start id=\"#{suggestion.anchor.marker_id}\" -->")
    expect(parse_body.dig("design_doc", "rendered_markdown")).to eq("Hello world")
    expect(DesignDocs::AnchorMarkers.strip(doc.markdown)).to eq("Hello world")
  end

  it "enforces agent write restrictions from server-side auth context even when params claim a user actor" do
    doc = create_design_doc(markdown: "canonical")
    owner.generate_api_token!

    expect {
      patch(
        "/api/v1/app/design_docs/#{doc.id}",
        params: {
          actor_kind: "user",
          design_doc: {
            markdown: "agent rewrite",
            change_summary: "Agent proposal"
          }
        },
        headers: { "Authorization" => "Bearer #{owner.api_token}" }
      )
    }.to change(DesignDocSuggestion, :count).by(1)
      .and change(DesignDocVersion, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("mode")).to eq("suggestion")
    expect(DesignDocSuggestion.last.suggested_by_kind).to eq("agent")
    expect(DesignDocs::AnchorMarkers.strip(doc.reload.markdown)).to eq("canonical")
  end

  it "creates anchored comment threads with hidden markers and lets only owners resolve them" do
    doc = create_design_doc(markdown: "Alpha beta gamma")
    doc.collaborators.create!(user: collaborator, role: "editor", added_by_user: owner)
    sign_in_as(collaborator)

    expect {
      post "/api/v1/app/design_docs/#{doc.id}/comments", params: {
        comment: {
          body: "Needs evidence",
          start_offset: 6,
          end_offset: 10,
          selected_markdown: "beta"
        }
      }
    }.to change(DesignDocThread, :count).by(1)
      .and change(DesignDocComment, :count).by(1)
      .and change(DesignDocVersion, :count).by(1)

    expect(response).to have_http_status(:created)
    thread = DesignDocThread.last
    expect(parse_body.dig("thread", "anchor")).to include(
      "anchor_kind" => "range",
      "selected_text" => "beta"
    )
    expect(parse_body.dig("comment", "body")).to eq("Needs evidence")
    expect(parse_body.dig("design_doc", "rendered_markdown")).to eq("Alpha beta gamma")
    expect(doc.reload.markdown).to include("<!-- syrus:range-start id=\"#{thread.anchor.marker_id}\" -->")

    post "/api/v1/app/design_docs/#{doc.id}/threads/#{thread.id}/resolve"
    expect(response).to have_http_status(:forbidden)

    sign_in_as(owner)
    post "/api/v1/app/design_docs/#{doc.id}/threads/#{thread.id}/resolve"

    expect(response).to have_http_status(:ok)
    expect(thread.reload).to have_attributes(state: "resolved", resolved_by_user: owner)
  end

  it "returns anchored threads and suggestions from the document detail API" do
    doc = create_design_doc(markdown: "Alpha beta gamma")
    doc.collaborators.create!(user: collaborator, role: "editor", added_by_user: owner)
    comment_result = ::DesignDocs::CreateComment.call(
      design_doc: doc,
      user: collaborator,
      attributes: { body: "Needs evidence", start_offset: 6, end_offset: 10, selected_markdown: "beta" }
    )
    suggestion_result = ::DesignDocs::CreateSuggestion.call(
      design_doc: doc.reload,
      user: collaborator,
      attributes: { start_offset: 11, end_offset: 16, original_markdown: "gamma", proposed_markdown: "delta" }
    )
    sign_in_as(owner)

    get "/api/v1/app/design_docs/#{doc.id}"

    expect(response).to have_http_status(:ok)
    body = parse_body.fetch("design_doc")
    expect(body.fetch("rendered_markdown")).to eq("Alpha beta gamma")
    expect(body.fetch("threads").first).to include(
      "id" => comment_result.thread.id,
      "state" => "open"
    )
    expect(body.dig("threads", 0, "comments", 0)).to include(
      "id" => comment_result.comment.id,
      "body" => "Needs evidence"
    )
    expect(body.fetch("suggestions").first).to include(
      "id" => suggestion_result.suggestion.id,
      "state" => "pending",
      "proposed_markdown" => "delta",
      "change_type" => "replace"
    )
  end

  it "serializes preloaded thread comments without re-querying each thread" do
    doc = create_design_doc(markdown: "Alpha beta gamma delta")
    doc.collaborators.create!(user: collaborator, role: "editor", added_by_user: owner)
    3.times do |index|
      ::DesignDocs::CreateComment.call(
        design_doc: doc.reload,
        user: collaborator,
        attributes: {
          body: "Comment #{index}",
          start_offset: index,
          end_offset: index + 1,
          selected_markdown: doc.markdown[index]
        }
      )
    end
    sign_in_as(owner)

    queries = capture_sql { get "/api/v1/app/design_docs/#{doc.id}" }

    expect(response).to have_http_status(:ok)
    comment_loads = queries.grep(/FROM "?design_doc_comments"?/i)
    expect(comment_loads.size).to eq(1)
    expect(parse_body.dig("design_doc", "threads").flat_map { |thread| thread.fetch("comments") }.size).to eq(3)
  end

  it "accepts owner-reviewed suggestions server-side when the anchored original text still matches" do
    doc = create_design_doc(markdown: "Hello world")
    doc.collaborators.create!(user: collaborator, role: "editor", added_by_user: owner)
    sign_in_as(collaborator)

    post "/api/v1/app/design_docs/#{doc.id}/suggestions", params: {
      suggestion: {
        start_offset: 6,
        end_offset: 11,
        original_markdown: "world",
        proposed_markdown: "Syrus",
        change_type: "replace",
        change_summary: "Use product name"
      }
    }
    expect(response).to have_http_status(:created)
    suggestion = DesignDocSuggestion.last
    expect(DesignDocs::AnchorMarkers.strip(doc.reload.markdown)).to eq("Hello world")
    expect(suggestion.provenance).to include("suggested_by_user_id" => collaborator.id)

    sign_in_as(owner)
    expect {
      post "/api/v1/app/design_docs/#{doc.id}/suggestions/#{suggestion.id}/accept"
    }.to change(DesignDocVersion, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("suggestion", "state")).to eq("accepted")
    expect(parse_body.dig("version", "version_number")).to eq(3)
    expect(DesignDocs::AnchorMarkers.strip(doc.reload.markdown)).to eq("Hello Syrus")
    expect(doc.markdown).to include("<!-- syrus:range-start id=\"#{suggestion.anchor.marker_id}\" -->")
  end

  it "rejects suggestions without mutating canonical markdown" do
    doc = create_design_doc(markdown: "Hello world")
    doc.collaborators.create!(user: collaborator, role: "editor", added_by_user: owner)
    suggestion = ::DesignDocs::CreateSuggestion.call(
      design_doc: doc,
      user: collaborator,
      attributes: { start_offset: 6, end_offset: 11, original_markdown: "world", proposed_markdown: "Syrus" }
    ).suggestion
    marked_markdown = doc.reload.markdown
    sign_in_as(owner)

    expect {
      post "/api/v1/app/design_docs/#{doc.id}/suggestions/#{suggestion.id}/reject"
    }.not_to change(DesignDocVersion, :count)

    expect(response).to have_http_status(:ok)
    expect(suggestion.reload.state).to eq("rejected")
    expect(doc.reload.markdown).to eq(marked_markdown)
    expect(DesignDocs::AnchorMarkers.strip(doc.markdown)).to eq("Hello world")
  end

  it "marks suggestions stale when the anchored original text changed before owner acceptance" do
    doc = create_design_doc(markdown: "Hello world")
    doc.collaborators.create!(user: collaborator, role: "editor", added_by_user: owner)
    suggestion = ::DesignDocs::CreateSuggestion.call(
      design_doc: doc,
      user: collaborator,
      attributes: { start_offset: 6, end_offset: 11, original_markdown: "world", proposed_markdown: "Syrus" }
    ).suggestion
    doc.update!(markdown: doc.markdown.sub("world", "earth"))
    sign_in_as(owner)

    expect {
      post "/api/v1/app/design_docs/#{doc.id}/suggestions/#{suggestion.id}/accept"
    }.not_to change(DesignDocVersion, :count)

    expect(response).to have_http_status(:conflict)
    expect(suggestion.reload.state).to eq("stale")
    expect(suggestion.anchor.reload.status).to eq("stale")
    expect(DesignDocs::AnchorMarkers.strip(doc.reload.markdown)).to eq("Hello earth")
  end

  it "marks suggestions conflicted when their anchor markers are missing" do
    doc = create_design_doc(markdown: "Hello world")
    doc.collaborators.create!(user: collaborator, role: "editor", added_by_user: owner)
    suggestion = ::DesignDocs::CreateSuggestion.call(
      design_doc: doc,
      user: collaborator,
      attributes: { start_offset: 6, end_offset: 11, original_markdown: "world", proposed_markdown: "Syrus" }
    ).suggestion
    doc.update!(markdown: DesignDocs::AnchorMarkers.strip(doc.markdown))
    sign_in_as(owner)

    expect {
      post "/api/v1/app/design_docs/#{doc.id}/suggestions/#{suggestion.id}/accept"
    }.not_to change(DesignDocVersion, :count)

    expect(response).to have_http_status(:conflict)
    expect(suggestion.reload.state).to eq("conflict")
    expect(suggestion.anchor.reload.status).to eq("missing")
  end

  it "rejects unsupported suggestion change types in v1" do
    doc = create_design_doc(markdown: "Hello world")
    doc.collaborators.create!(user: collaborator, role: "editor", added_by_user: owner)
    sign_in_as(collaborator)

    expect {
      post "/api/v1/app/design_docs/#{doc.id}/suggestions", params: {
        suggestion: {
          start_offset: 6,
          end_offset: 11,
          original_markdown: "world",
          proposed_markdown: "",
          change_type: "delete"
        }
      }
    }.not_to change(DesignDocSuggestion, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to include("Change type is not included in the list")
    expect(DesignDocs::AnchorMarkers.strip(doc.reload.markdown)).to eq("Hello world")
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

  it "preloads version actors when returning version history" do
    doc = create_design_doc(markdown: "v1")
    reviewer = Factories.user(email_address: "reviewer@example.com")
    second_reviewer = Factories.user(email_address: "reviewer2@example.com")
    doc.versions.create!(markdown: "v2", version_number: 2, actor_kind: "user", actor_user: reviewer)
    doc.versions.create!(markdown: "v3", version_number: 3, actor_kind: "user", actor_user: second_reviewer)
    sign_in_as(owner)

    user_selects = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      next if payload[:name].to_s.match?(/\ASCHEMA|TRANSACTION\z/)
      next unless sql.match?(/\bFROM [`"]?users[`"]?/i)

      user_selects << sql
    end

    get "/api/v1/app/design_docs/#{doc.id}/versions"

    ActiveSupport::Notifications.unsubscribe(subscriber)
    subscriber = nil
    expect(response).to have_http_status(:ok)
    expect(user_selects.size).to be <= 3
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if defined?(subscriber) && subscriber
  end
end
