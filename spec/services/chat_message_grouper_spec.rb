require "rails_helper"

RSpec.describe ChatMessageGrouper do
  let(:user) { Factories.user(claude_oauth_token: "oat") }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat) { ChatSession.create!(repository: repo, user: user, last_message_at: Time.current) }

  def msg_text(role, text)
    chat.messages.create!(role: role, content: { "text" => text })
  end

  def tool_use(tool_name, input)
    chat.messages.create!(role: "tool_use", tool_name: tool_name, content: { "input" => input })
  end

  def tool_result(tool_name, result, is_error: false)
    chat.messages.create!(
      role: "tool_result",
      tool_name: tool_name,
      content: { "result" => result, "is_error" => is_error }
    )
  end

  it "passes through plain user/assistant/system messages" do
    u = msg_text("user", "hi")
    a = msg_text("assistant", "hello")
    s = msg_text("system", "ok")

    items = described_class.group([ u, a, s ])

    expect(items).to eq([
      { type: :message, message: u },
      { type: :message, message: a },
      { type: :message, message: s }
    ])
  end

  it "groups consecutive tool_use messages of the same tool_name" do
    a = tool_use("Read", { "file_path" => "a.py" })
    b = tool_use("Read", { "file_path" => "b.py" })
    c = tool_use("Read", { "file_path" => "c.py" })

    items = described_class.group([ a, b, c ])

    expect(items.size).to eq(1)
    group = items.first
    expect(group[:type]).to eq(:tool_group)
    expect(group[:tool]).to eq("Read")
    expect(group[:calls].map { |c| c[:detail] }).to eq([ "a.py", "b.py", "c.py" ])
  end

  it "starts a new group when the tool name changes" do
    items = described_class.group([
      tool_use("Read", { "file_path" => "a.py" }),
      tool_use("Bash", { "command" => "ls" })
    ])

    expect(items.map { |i| i[:tool] }).to eq([ "Read", "Bash" ])
  end

  it "attaches a tool_result to the last tool_use in the current group" do
    a = tool_use("Read", { "file_path" => "a.py" })
    r = tool_result("Read", [ { "type" => "text", "text" => "file contents..." } ])

    items = described_class.group([ a, r ])

    expect(items.first[:calls].first[:result]).to eq(r)
  end

  it "breaks the current group when a non-tool message arrives between calls" do
    items = described_class.group([
      tool_use("Read", { "file_path" => "a.py" }),
      msg_text("assistant", "Done."),
      tool_use("Read", { "file_path" => "b.py" })
    ])

    expect(items.map { |i| i[:type] }).to eq([ :tool_group, :message, :tool_group ])
  end

  it "uses the abbreviator's per-tool resolver to derive the detail" do
    items = described_class.group([
      tool_use("Bash", { "command" => "git status" }),
      tool_use("Grep", { "pattern" => "TODO", "path" => "app" })
    ])

    details = items.map { |i| i[:calls].first[:detail] }
    expect(details).to eq([ "git status", "TODO in app" ])
  end

  it "shortens chat workspace paths to repository-relative details" do
    root = ChatWorkspace.repo_path_for(chat, repo).to_s

    items = described_class.group([
      tool_use("Read", { "file_path" => "#{root}/app/models/widget.rb" }),
      tool_use("Bash", { "command" => "find #{root} -type f -name '*.rb'" })
    ], repository: repo)

    details = items.map { |i| i[:calls].first[:detail] }
    expect(details).to eq([ "app/models/widget.rb", "find . -type f -name '*.rb'" ])
  end

  it "leaves tool_use messages with a proposal as standalone passthroughs" do
    proposal = ChatProposal.create!(chat_session: chat, slug: "x", title: "X", body: "x.")
    m = chat.messages.create!(role: "tool_use", tool_name: "propose_issue", proposal: proposal, content: { "input" => { "slug" => "x" } })

    items = described_class.group([ m ])

    expect(items).to eq([ { type: :message, message: m } ])
  end
end
