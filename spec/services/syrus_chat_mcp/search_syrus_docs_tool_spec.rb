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
    # Plugins contribute their own docs (and a teaser when disabled), so these
    # examples pin the plugin set rather than depending on which plugins happen
    # to be bundled. Resetting the whole registry is too blunt -- User
    # validation reads agent providers from it.
    allow(Syrus::PluginRegistry).to receive(:all_plugins).and_return([])
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

  # A plugin's docs live in the plugin, so deleting the plugin directory takes
  # them with it; core only sees them while the plugin is enabled.
  describe "plugin documentation" do
    def manifest(name:, enabled:, long_description: "Opens a real PTY on the worker and streams it to the browser.")
      instance_double(
        Syrus::Plugin::Manifest,
        name: name, display_name: name.capitalize, enabled?: enabled,
        long_description: long_description, description: "short blurb",
        # The stub is global, so unrelated machinery (domain event delivery
        # during User.create!) walks these manifests too.
        provides: {}
      )
    end

    def with_plugins(*manifests)
      allow(Syrus::PluginRegistry).to receive(:all_plugins).and_return(manifests)
    end

    it "searches an enabled plugin's own docs" do
      dir = Pathname.new(Dir.mktmpdir)
      (dir / "terminal.md").write("# Terminal\n\n## Sessions\nA session survives browser navigation.\n")
      allow(described_class).to receive(:plugin_docs_dir).with("terminal").and_return(dir)
      with_plugins(manifest(name: "terminal", enabled: true))

      expect(response_text(call_tool(query: "session survives navigation"))).to include("survives browser navigation")
    ensure
      FileUtils.rm_rf(dir)
    end

    it "does not search a disabled plugin's docs" do
      dir = Pathname.new(Dir.mktmpdir)
      (dir / "terminal.md").write("# Terminal\n\n## Sessions\nA session survives browser navigation.\n")
      allow(described_class).to receive(:plugin_docs_dir).with("terminal").and_return(dir)
      with_plugins(manifest(name: "terminal", enabled: false))

      expect(response_text(call_tool(query: "session survives navigation"))).not_to include("survives browser navigation")
    ensure
      FileUtils.rm_rf(dir)
    end

    # Otherwise an agent asking about a capability is told it does not exist,
    # when it is one toggle away.
    it "offers a teaser for a disabled plugin, leading with the fact that it is off" do
      with_plugins(manifest(name: "terminal", enabled: false))

      text = response_text(call_tool(query: "terminal"))

      expect(text).to include("Terminal (plugin disabled)")
      expect(text).to include("currently DISABLED")
      expect(text).to include("Admin -> Plugins")
      expect(text).to include("plugin name: terminal")
    end

    it "gives an enabled plugin no teaser" do
      allow(described_class).to receive(:plugin_docs_dir).and_return(Pathname.new(Dir.mktmpdir))
      with_plugins(manifest(name: "terminal", enabled: true))

      expect(response_text(call_tool(query: "terminal"))).not_to include("plugin disabled")
    end

    it "skips a disabled plugin with nothing to say rather than offering an empty teaser" do
      with_plugins(manifest(name: "terminal", enabled: false, long_description: nil))

      text = response_text(call_tool(query: "terminal"))

      expect(text).to include("No matching documentation").or include("short blurb")
    end
  end
end
