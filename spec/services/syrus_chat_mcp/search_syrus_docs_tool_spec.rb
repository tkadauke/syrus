require "rails_helper"

RSpec.describe Mcp::Tools::SearchSyrusDocsTool do
  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(arguments = {})
    raw = server.handle_json({
      jsonrpc: "2.0", id: 1, method: "tools/call",
      params: { name: "search_syrus_docs", arguments: arguments }
    }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def response_text(response)
    response.fetch(:result).fetch(:content).first.fetch(:text)
  end

  before do
    @docs_dir = Pathname.new(Dir.mktmpdir)
    allow(described_class).to receive(:docs_dir).and_return(@docs_dir)
  end

  after do
    FileUtils.rm_rf(@docs_dir)
  end

  def write_doc(name, content)
    (@docs_dir / name).write(content)
  end

  it "returns relevant sections when query matches" do
    write_doc("prepare.md", <<~MD)
      # Prepare Step

      ## Overview
      The prepare step runs setup commands before the agent.

      ## Commands
      Run bundle install and npm ci from the prepare list.
    MD

    response = call_tool(query: "bundle install")
    text = response_text(response)

    expect(response[:result][:isError]).to be_falsey
    expect(text).to include("## Prepare Step >")
    expect(text).to include("bundle install")
  end

  it "returns at most 3 sections" do
    # Four docs each with one matching section
    %w[alpha beta gamma delta].each do |name|
      write_doc("#{name}.md", <<~MD)
        # #{name.capitalize} Doc

        ## Section
        This section mentions the keyword frobulate.
      MD
    end

    response = call_tool(query: "frobulate")
    text = response_text(response)

    expect(response[:result][:isError]).to be_falsey
    section_count = text.split("\n\n---\n\n").length
    expect(section_count).to eq(described_class::MAX_RESULTS)
  end

  it "returns a not-found message when nothing matches" do
    write_doc("something.md", <<~MD)
      # Something

      ## A Section
      Words about something entirely unrelated.
    MD

    response = call_tool(query: "xyzzy gobbledygook")
    text = response_text(response)

    expect(response[:result][:isError]).to be_falsey
    expect(text).to eq("No matching documentation found for 'xyzzy gobbledygook'. Try broader terms.")
  end

  it "handles an empty corpus directory gracefully" do
    # @docs_dir exists but has no .md files
    response = call_tool(query: "anything")
    text = response_text(response)

    expect(response[:result][:isError]).to be_falsey
    expect(text).to include("No matching documentation found for 'anything'")
  end

  it "handles a missing corpus directory gracefully" do
    allow(described_class).to receive(:docs_dir).and_return(Pathname.new("/nonexistent/path/syrus_docs"))

    response = call_tool(query: "anything")
    text = response_text(response)

    expect(response[:result][:isError]).to be_falsey
    expect(text).to include("No matching documentation found for 'anything'")
  end

  it "truncates long section bodies to MAX_SECTION_CHARS characters" do
    long_body = "x" * 1000
    write_doc("long.md", <<~MD)
      # Long Doc

      ## Big Section
      #{long_body}
    MD

    response = call_tool(query: "long")
    text = response_text(response)

    section_body = text.split("\n", 2).last
    expect(section_body.length).to be <= described_class::MAX_SECTION_CHARS + 10
    expect(text).to include("…")
  end

  it "matches case-insensitively" do
    write_doc("graders.md", <<~MD)
      # Graders

      ## Overview
      GRADER commands run after each implement step.
    MD

    response = call_tool(query: "grader")
    text = response_text(response)

    expect(response[:result][:isError]).to be_falsey
    expect(text).to include("## Graders >")
  end

  it "returns an error for a blank query" do
    response = call_tool(query: "")
    expect(response[:result][:isError]).to be_truthy
  end
end
