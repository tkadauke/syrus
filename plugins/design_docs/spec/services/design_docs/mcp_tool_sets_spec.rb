require "rails_helper"

RSpec.describe "DesignDocs MCP tool sets" do
  let(:owner) { Factories.user(email_address: "owner@example.com") }
  let(:collaborator) { Factories.user(email_address: "collaborator@example.com") }
  let(:repository) { Factories.repository(user: owner, owner: "acme", name: "widgets") }
  let(:chat_session) { ChatSession.create!(user: owner, repository: repository) }

  def create_design_doc(user: owner, repo: repository, title: "Checkout design", markdown: "Hello world", visibility: "public")
    doc = DesignDocs::DesignDoc.create!(
      owner_user: user,
      title: title,
      markdown: markdown,
      visibility: visibility
    )
    version = doc.versions.create!(
      markdown: doc.markdown,
      version_number: 1,
      actor_kind: "user",
      actor_user: user
    )
    doc.update!(current_version: version)
    doc.repositories << repo if repo
    doc
  end

  def chat_server(current_message: nil)
    tools = DesignDocs::ChatToolSet.tool_definitions(tier: :essential).map do |definition|
      MCP::Tool.define(
        name: definition.fetch(:name),
        description: definition.fetch(:description),
        input_schema: definition.fetch(:input_schema)
      ) do |server_context:, **params|
        DesignDocs::ChatToolSet.new.handle(definition.fetch(:name), params, server_context)
      end
    end

    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: tools,
      server_context: { chat_session: chat_session, current_message: current_message }.compact
    )
  end

  def workflow_server(run)
    context = McpToolContext.from_run(run)
    tools = DesignDocs::WorkflowToolSet.tool_definitions(context: context).map do |definition|
      MCP::Tool.define(
        name: definition.fetch(:name),
        description: definition.fetch(:description),
        input_schema: definition.fetch(:input_schema)
      ) do |server_context:, **params|
        DesignDocs::WorkflowToolSet.new.handle(definition.fetch(:name), params, server_context)
      end
    end

    MCP::Server.new(name: "syrus-mcp-sidecar", tools: tools, server_context: { run_id: run.id })
  end

  def call_tool(server, name, arguments = {})
    raw = server.handle_json({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: name, arguments: arguments }
    }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def tool_names(server)
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json)
    JSON.parse(raw, symbolize_names: true).dig(:result, :tools).map { |tool| tool.fetch(:name) }
  end

  def response_payload(response)
    JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
  end

  def workflow_run
    job = Factories.job(repository: repository)
    step = job.workflows.last.steps.find_by!(kind: "implement")
    step.runs.create!(job: job, trigger_kind: "initial", agent_provider: "codex", iteration: 1)
  end

  it "exposes read/write tools to chat agents and only read tools to workflow agents" do
    chat_names = tool_names(chat_server)
    run = workflow_run
    workflow_names = tool_names(workflow_server(run))

    expect(DesignDocs::ChatToolSet.available_for?(chat_session, tier: :essential)).to be(false)
    expect(DesignDocs::ChatToolSet.available_for?(chat_session, tier: :deferred)).to be(true)
    expect(chat_names).to include(
      "list_design_docs",
      "read_design_doc",
      "propose_design_doc",
      "comment_on_design_doc",
      "suggest_design_doc_change"
    )
    expect(workflow_names).to contain_exactly("list_design_docs", "read_design_doc")
  end

  it "keeps DOC reference and suggestion-only semantics explicit in tool descriptions" do
    definitions = DesignDocs::ChatToolSet.tool_definitions(tier: :essential)
    read = definitions.find { |definition| definition.fetch(:name) == "read_design_doc" }
    suggest = definitions.find { |definition| definition.fetch(:name) == "suggest_design_doc_change" }

    expect(read.fetch(:description)).to include("DOC-<id>")
    expect(suggest.fetch(:description)).to include("suggestion-only")
    expect(suggest.fetch(:description)).to include("never directly mutates canonical Markdown")
  end

  it "scopes workflow reads to design docs visible through the run repository" do
    linked = create_design_doc(title: "Repository plan")
    other_repo = Factories.repository(user: owner, owner: "acme", name: "elsewhere")
    create_design_doc(repo: other_repo, title: "Other plan")
    run = workflow_run
    server = workflow_server(run)

    list_response = call_tool(server, "list_design_docs")
    list_payload = response_payload(list_response)

    expect(list_payload.fetch(:design_docs).pluck(:doc_ref)).to eq([ linked.display_id ])

    read_response = call_tool(server, "read_design_doc", doc_ref: linked.display_id)
    expect(response_payload(read_response).dig(:design_doc, :doc_ref)).to eq(linked.display_id)

    denied = call_tool(server, "read_design_doc", doc_ref: "DOC-#{DesignDocs::DesignDoc.last.id}")
    expect(denied.dig(:result, :isError)).to be true
    expect(denied.dig(:result, :content, 0, :text)).to include("design doc not found in this agent context")
  end

  it "creates agent-owned suggestions with chat provenance and leaves canonical markdown unchanged" do
    doc = create_design_doc(markdown: "Hello world")
    assistant_message = chat_session.messages.create!(role: "assistant", content: { "text" => "" })
    server = chat_server(current_message: assistant_message)

    expect {
      response = call_tool(
        server,
        "suggest_design_doc_change",
        doc_ref: doc.display_id,
        start_offset: 6,
        end_offset: 11,
        original_markdown: "world",
        proposed_markdown: "Syrus",
        change_summary: "Use product name"
      )
      expect(response.dig(:result, :isError)).to be_falsey
    }.to change(DesignDocs::DesignDocSuggestion, :count).by(1)
      .and change(DesignDocs::DesignDocVersion, :count).by(1)

    suggestion = DesignDocs::DesignDocSuggestion.last
    expect(suggestion).to have_attributes(
      suggested_by_kind: "agent",
      suggested_by_user: nil,
      original_markdown: "world",
      suggested_markdown: "Syrus"
    )
    expect(suggestion.provenance).to include(
      "actor_kind" => "agent",
      "chat_message_id" => assistant_message.id
    )
    expect(DesignDocs::AnchorMarkers.strip(doc.reload.markdown)).to eq("Hello world")
  end

  it "records chat-agent comments as agent-authored anchored discussion" do
    doc = create_design_doc(markdown: "Alpha beta gamma")
    server = chat_server

    expect {
      response = call_tool(
        server,
        "comment_on_design_doc",
        doc_ref: doc.display_id,
        body: "Needs evidence",
        start_offset: 6,
        end_offset: 10,
        selected_markdown: "beta"
      )
      expect(response.dig(:result, :isError)).to be_falsey
    }.to change(DesignDocs::DesignDocComment, :count).by(1)

    comment = DesignDocs::DesignDocComment.last
    expect(comment).to have_attributes(author_kind: "agent", author_user: nil, body: "Needs evidence")
    expect(comment.thread.anchor).to have_attributes(start_offset: 6, end_offset: 10, selected_text: "beta")
  end

  it "denies direct canonical markdown mutation from agent actor contexts" do
    doc = create_design_doc(markdown: "canonical", visibility: "private")

    result = DesignDocs::Update.call(
      design_doc: doc,
      user: owner,
      actor_kind: "agent",
      attributes: {
        markdown: "agent rewrite",
        start_offset: 0,
        end_offset: 9,
        selected_markdown: "canonical",
        change_summary: "Rewrite"
      }
    )

    expect(result.mode).to eq("suggestion")
    expect(result.suggestion).to have_attributes(suggested_by_kind: "agent", suggested_by_user: nil)
    expect(DesignDocs::AnchorMarkers.strip(doc.reload.markdown)).to eq("canonical")
  end

  it "creates new design docs from chat with agent initial-version provenance" do
    server = chat_server

    expect {
      response = call_tool(server, "propose_design_doc", title: "Payments RFC", markdown: "# Payments")
      expect(response.dig(:result, :isError)).to be_falsey
      expect(response_payload(response).fetch(:doc_ref)).to match(/\ADOC-\d+\z/)
    }.to change(DesignDocs::DesignDoc, :count).by(1)

    doc = DesignDocs::DesignDoc.last
    expect(doc.origin_chat_session).to eq(chat_session)
    expect(doc.repositories).to contain_exactly(repository)
    expect(doc.current_version).to have_attributes(actor_kind: "agent", actor_user: nil)
  end
end
