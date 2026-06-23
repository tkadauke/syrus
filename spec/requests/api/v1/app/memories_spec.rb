require "rails_helper"

RSpec.describe "API: /api/v1/app/memories", type: :request do
  let!(:seed_admin) { Factories.user(admin: true) }
  let(:user) { Factories.user }
  let(:other) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:other_repository) { Factories.repository(user: other, owner: "acme", name: "widgets") }

  def parse_body = JSON.parse(response.body)

  def memory_for(owner, **attrs)
    ChatMemory.create!({
      user: owner,
      kind: "project_fact",
      scope: "repository",
      scope_id: repository.id,
      content: "Use Rails for the app."
    }.merge(attrs))
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/memories"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "lists own memories and published memories from attached repositories" do
    sign_in_as(user)
    own_global = memory_for(user, scope: "global", scope_id: nil, kind: "user_pref", content: "Prefer concise status updates.")
    own_repo = memory_for(user, content: "Use SQLite in test.")
    published = memory_for(other, scope_id: repository.id, content: "Shared deploy runbook.", published: true)
    memory_for(other, scope_id: repository.id, content: "Private draft.")
    memory_for(other, scope_id: other_repository.id, content: "Different repo.", published: true)

    get "/api/v1/app/memories"

    expect(response).to have_http_status(:ok)
    ids = parse_body["memories"].map { |row| row["id"] }
    expect(ids).to contain_exactly(own_global.id, own_repo.id, published.id)
    expect(parse_body["repositories"]).to include("id" => repository.id, "name" => "acme/widgets")
    expect(parse_body["current_user"]).to include("id" => user.id, "admin" => false)
  end

  it "filters by scope, kind, and search query" do
    sign_in_as(user)
    matching = memory_for(user, kind: "reference", content: "Payments runbook lives in Drive.")
    memory_for(user, kind: "decision", content: "Use Redis later.")
    memory_for(user, scope: "global", scope_id: nil, kind: "reference", content: "Payments preference.")

    get "/api/v1/app/memories", params: { scope: "repository", kind: "reference", q: "runbook" }

    expect(response).to have_http_status(:ok)
    expect(parse_body["memories"].map { |row| row["id"] }).to eq([ matching.id ])
  end

  it "paginates memories" do
    sign_in_as(user)
    21.times { |index| memory_for(user, content: "Memory #{index}") }

    get "/api/v1/app/memories", params: { page: 2 }

    expect(response).to have_http_status(:ok)
    expect(parse_body["memories"].size).to eq(1)
    expect(parse_body["pagination"]).to include("page" => 2, "per_page" => 20, "total" => 21, "total_pages" => 2)
  end

  it "creates a memory owned by the current user" do
    sign_in_as(user)

    expect {
      post "/api/v1/app/memories", params: {
        memory: {
          kind: "project_fact",
          scope: "repository",
          repository_id: repository.id,
          content: "Run frontend tests with bin/test-react."
        }
      }
    }.to change { user.chat_memories.count }.by(1)

    expect(response).to have_http_status(:created)
    memory = user.chat_memories.last
    expect(memory.scope_id).to eq(repository.id)
    expect(parse_body["message"]).to eq("Memory created.")
  end

  it "updates only content and kind" do
    sign_in_as(user)
    memory = memory_for(user, kind: "reference")

    patch "/api/v1/app/memories/#{memory.id}", params: {
      memory: {
        kind: "decision",
        scope: "global",
        content: "Keep app API payloads compact."
      }
    }

    expect(response).to have_http_status(:ok)
    expect(memory.reload).to have_attributes(kind: "decision", scope: "repository", content: "Keep app API payloads compact.")
  end

  it "forbids non-admin writes to another user's memories" do
    sign_in_as(user)
    memory = memory_for(other, scope_id: repository.id, published: true, content: "Shared but not yours.")

    patch "/api/v1/app/memories/#{memory.id}", params: { memory: { content: "stolen" } }

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
    expect(memory.reload.content).to eq("Shared but not yours.")
  end

  it "allows admins to manage any memory and exposes owner data" do
    admin = Factories.user(admin: true)
    sign_in_as(admin)
    memory = memory_for(other, scope_id: other_repository.id, content: "Admin visible.")

    patch "/api/v1/app/memories/#{memory.id}", params: { memory: { content: "Admin edited.", kind: "decision" } }

    expect(response).to have_http_status(:ok)
    row = parse_body["memories"].find { |item| item["id"] == memory.id }
    expect(memory.reload.content).to eq("Admin edited.")
    expect(row.dig("owner", "id")).to eq(other.id)
    expect(row.dig("permissions", "can_manage")).to be(true)
  end

  it "publishes and unpublishes repository memories" do
    sign_in_as(user)
    memory = memory_for(user, published: false)

    post "/api/v1/app/memories/#{memory.id}/publish"

    expect(response).to have_http_status(:ok)
    expect(memory.reload.published).to be(true)

    delete "/api/v1/app/memories/#{memory.id}/publish"

    expect(response).to have_http_status(:ok)
    expect(memory.reload.published).to be(false)
  end

  it "rejects publishing global memories" do
    sign_in_as(user)
    memory = memory_for(user, scope: "global", scope_id: nil)

    post "/api/v1/app/memories/#{memory.id}/publish"

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to include("repository-scoped")
  end

  it "deletes owned memories" do
    sign_in_as(user)
    memory = memory_for(user)

    expect {
      delete "/api/v1/app/memories/#{memory.id}"
    }.to change { ChatMemory.exists?(memory.id) }.from(true).to(false)

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Memory deleted.")
  end
end
