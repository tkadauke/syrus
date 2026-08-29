require "rails_helper"

RSpec.describe "DesignDocs MCP tool sets" do
  let(:owner) { Factories.user(email_address: "owner@example.com") }
  let(:collaborator) { Factories.user(email_address: "collab@example.com") }
  let(:outsider) { Factories.user(email_address: "outsider@example.com") }
  let(:repository) { Factories.repository(user: owner, owner: "acme", name: "widgets") }
  let(:chat_session) { ChatSession.create!(user: owner, repository: repository) }

  def create_design_doc(user: owner, repo: repository, **attrs)
    doc = DesignDoc.create!({
      owner_user: user,
      title: "Checkout design",
      markdown: "Hello world",
      visibility: "private"
    }.merge(attrs))
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

  def json(response)
    JSON.parse(response.content.first[:text])
  end

  describe DesignDocs::ChatToolSet do
    let(:tool_set) { described_class.new }

    def call(tool_name, params = {}, session: chat_session, current_message: nil)
      tool_set.handle(tool_name, params, { chat_session: session, current_message: current_message }.compact)
    end

    it "advertises chat read and suggestion-only write tools" do
      names = described_class.tool_definitions(tier: :essential).map { |definition| definition.fetch(:name) }

      expect(names).to contain_exactly(
        "list_design_docs",
        "read_design_doc",
        "propose_design_doc",
        "comment_on_design_doc",
        "suggest_design_doc_change"
      )
      suggest_description = described_class.tool_definitions(tier: :essential).find { |definition| definition[:name] == "suggest_design_doc_change" }[:description]
      expect(suggest_description).to include("DOC-<id>")
      expect(suggest_description).to include("suggestion-only")
    end

    it "lists and reads only docs visible to the chat user" do
      visible = create_design_doc(title: "Visible private")
      hidden = create_design_doc(user: outsider, repo: Factories.repository(user: outsider), title: "Hidden private")

      list_response = call("list_design_docs")
      read_response = call("read_design_doc", { "doc_ref" => visible.display_id })
      hidden_response = call("read_design_doc", { "doc_ref" => hidden.display_id })

      expect(json(list_response).fetch("design_docs").map { |doc| doc.fetch("display_id") }).to include(visible.display_id)
      expect(json(list_response).fetch("design_docs").map { |doc| doc.fetch("display_id") }).not_to include(hidden.display_id)
      expect(json(read_response).dig("design_doc", "markdown")).to eq("Hello world")
      expect(hidden_response).to be_error
    end

    it "rejects an inaccessible repository_id filter instead of broadening chat results" do
      visible = create_design_doc(title: "Visible private")
      inaccessible_repo = Factories.repository(user: outsider, owner: "other", name: "private")

      response = call("list_design_docs", { "repository_id" => inaccessible_repo.id })

      expect(response).to be_error
      expect(response.content.first[:text]).to include("repository not found or not accessible")
      expect(json(call("list_design_docs")).fetch("design_docs").map { |doc| doc.fetch("display_id") }).to include(visible.display_id)
    end

    it "creates new design doc proposals with agent version provenance" do
      expect {
        response = call("propose_design_doc", {
          "title" => "Agent-authored plan",
          "markdown" => "# Plan",
          "repository_ids" => [ repository.id ],
          "change_summary" => "Draft from chat"
        })

        expect(response).not_to be_error
        expect(json(response).fetch("reference")).to match(/\ADOC-\d+\z/)
      }.to change(DesignDoc, :count).by(1)

      doc = DesignDoc.last
      expect(doc).to have_attributes(owner_user: owner, origin_chat_session: chat_session)
      expect(doc.repositories).to contain_exactly(repository)
      expect(doc.current_version).to have_attributes(actor_kind: "agent", actor_user: nil, change_summary: "Draft from chat")
    end

    it "creates agent comments and pending suggestions without directly changing canonical prose" do
      doc = create_design_doc(markdown: "Hello world")
      current_message = chat_session.messages.create!(role: "assistant", content: "I suggest a change.")

      comment_response = call("comment_on_design_doc", {
        "doc_ref" => doc.display_id,
        "body" => "Use the product name.",
        "start_offset" => 6,
        "end_offset" => 11,
        "selected_markdown" => "world"
      })
      suggestion_response = call("suggest_design_doc_change", {
        "doc_ref" => doc.display_id,
        "proposed_markdown" => "Syrus",
        "start_offset" => 6,
        "end_offset" => 11,
        "selected_markdown" => "world",
        "change_summary" => "Use product name"
      }, current_message: current_message)

      expect(comment_response).not_to be_error
      expect(suggestion_response).not_to be_error
      expect(DesignDocComment.last).to have_attributes(author_kind: "agent", author_user: nil)
      suggestion = DesignDocSuggestion.last
      expect(suggestion).to have_attributes(
        state: "pending",
        suggested_by_kind: "agent",
        suggested_by_user: nil,
        proposed_markdown: "Syrus"
      )
      expect(suggestion.provenance).to include("chat_message_id" => current_message.id)
      expect(DesignDocs::AnchorMarkers.strip(doc.reload.markdown)).to eq("Hello world")
    end

    it "does not permit agent-context direct canonical updates through the backend service" do
      doc = create_design_doc(markdown: "canonical")

      expect {
        result = DesignDocs::Update.call(
          design_doc: doc,
          user: owner,
          actor_kind: "agent",
          attributes: { markdown: "rewritten", change_summary: "Agent rewrite" }
        )
        expect(result.mode).to eq("suggestion")
      }.to change(DesignDocSuggestion, :count).by(1)

      expect(DesignDocs::AnchorMarkers.strip(doc.reload.markdown)).to eq("canonical")
    end
  end

  describe DesignDocs::WorkflowToolSet do
    let(:tool_set) { described_class.new }

    def workflow_context_for(user: owner, repo: repository)
      job = Factories.job(repository: repo, user: user)
      run = job.initial_run
      { run_id: run.id }
    end

    it "advertises only read-only tools to workflow agents" do
      names = described_class.tool_definitions(context: nil).map { |definition| definition.fetch(:name) }

      expect(names).to contain_exactly("list_design_docs", "read_design_doc")
      expect(names).not_to include("propose_design_doc", "comment_on_design_doc", "suggest_design_doc_change")
    end

    it "scopes worker reads to docs visible through the run user and repository" do
      readable = create_design_doc(title: "Repo plan")
      other_repo_doc = create_design_doc(title: "Other repo", repo: Factories.repository(user: owner, owner: "acme", name: "api"))
      hidden_private = create_design_doc(user: outsider, repo: repository, title: "Hidden private")
      context = workflow_context_for

      list_response = tool_set.handle("list_design_docs", {}, context)
      read_response = tool_set.handle("read_design_doc", { "doc_ref" => readable.display_id }, context)
      other_response = tool_set.handle("read_design_doc", { "doc_ref" => other_repo_doc.display_id }, context)
      hidden_response = tool_set.handle("read_design_doc", { "doc_ref" => hidden_private.display_id }, context)

      ids = json(list_response).fetch("design_docs").map { |doc| doc.fetch("display_id") }
      expect(ids).to include(readable.display_id)
      expect(ids).not_to include(other_repo_doc.display_id, hidden_private.display_id)
      expect(read_response).not_to be_error
      expect(other_response).to be_error
      expect(hidden_response).to be_error
    end
  end

  describe DesignDocs::PromptContext do
    it "surfaces readable DOC references for worker prompts" do
      doc = create_design_doc(title: "Checkout architecture")
      job = Factories.job(repository: repository, user: owner)

      output = described_class.call(repository: repository, job: job)

      expect(output).to include("## Design Docs Context")
      expect(output).to include("#{doc.display_id}: Checkout architecture")
      expect(output).to include("read_design_doc")
      expect(output).to include("Workflow agents only have read-only design doc tools")
    end
  end
end
