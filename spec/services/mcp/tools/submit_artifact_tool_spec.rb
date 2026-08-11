require "rails_helper"

RSpec.describe Mcp::Tools::SubmitArtifactTool do
  let(:user)         { Factories.user }
  let(:repository)   { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def call(type: "rails_schema_erd", title: "Schema ERD", payload: { "tables" => 3 }, server_context: { chat_session: chat_session })
    described_class.call(type: type, title: title, payload: payload, server_context: server_context)
  end

  it "appends a typed artifact entry to the chat session" do
    call

    entries = chat_session.reload.artifact("typed_artifacts")
    expect(entries.size).to eq(1)
    expect(entries.first).to include(
      "type"    => "rails_schema_erd",
      "title"   => "Schema ERD",
      "payload" => { "tables" => 3 }
    )
    expect(entries.first["created_at"]).to be_present
  end

  it "replaces an existing entry when called again with the same type" do
    call(payload: { "tables" => 3 })
    call(payload: { "tables" => 5 })

    entries = chat_session.reload.artifact("typed_artifacts")
    expect(entries.size).to eq(1)
    expect(entries.first["payload"]).to eq({ "tables" => 5 })
  end

  it "accumulates entries with different types" do
    call(type: "rails_schema_erd",       title: "ERD",            payload: {})
    call(type: "rails_migration_diff",   title: "Migration Diff", payload: {})

    entries = chat_session.reload.artifact("typed_artifacts")
    expect(entries.map { |e| e["type"] }).to contain_exactly("rails_schema_erd", "rails_migration_diff")
  end

  it "normalizes binary-tagged UTF-8 in type and title" do
    call(type: "rails_schema_erd".b, title: "Schema ERD".b)

    entries = chat_session.reload.artifact("typed_artifacts")
    expect(entries.first["type"].encoding).to eq(Encoding::UTF_8)
    expect(entries.first["title"].encoding).to eq(Encoding::UTF_8)
  end

  it "rejects an empty type" do
    response = call(type: "  ")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("type is required")
    expect(chat_session.reload.artifact("typed_artifacts")).to be_nil
  end

  it "rejects an empty title" do
    response = call(title: "  ")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("title is required")
    expect(chat_session.reload.artifact("typed_artifacts")).to be_nil
  end

  it "rejects a non-object payload" do
    response = call(payload: "not a hash")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("payload must be an object")
    expect(chat_session.reload.artifact("typed_artifacts")).to be_nil
  end

  it "exposes the expected tool name and required schema fields" do
    expect(described_class.tool_name).to eq("submit_artifact")
    expect(described_class.input_schema_value.to_h[:required]).to contain_exactly("type", "title", "payload")
  end
end
