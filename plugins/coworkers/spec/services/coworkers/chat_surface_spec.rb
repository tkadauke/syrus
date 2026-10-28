require "rails_helper"

RSpec.describe "Coworker chat surface" do
  let(:owner) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya",
      workspace_repo: repository.remote_url
    )
  end
  let(:chat) { ChatSession.create!(user: owner, repository: repository, title: "Maya") }
  let(:scope) { Syrus::EffectScope.new(label: "coworker surface spec") }

  before do
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    Coworkers::ChatExtension.install_into(scope)
  end

  after { scope.dispose }

  def names(tier: :essential)
    McpToolRegistry.tools_for_context(McpToolContext.from_chat_session(chat.reload), tier: tier)
      .map { |tool| McpToolRegistry.tool_name_for(tool) }
  end

  it "never gives an admin-owned coworker admin, repair, coding, local, or runtime tools" do
    coworker.grants.create!(capability: "syrus.read_jobs", approval_policy: "auto")

    expect(names).to contain_exactly("list_jobs", "search_jobs", "read_job")
    expect(names).not_to include("admin_overview", "force_fail_job", "run_command", "runtime_start")
  end

  it "advertises every tool only when its named grant exists" do
    entries = McpToolRegistry.entries(surface: :coworker)
    expect(entries).to all(have_attributes(capability: be_present))

    entries.reject(&:interactive_only).each do |entry|
      coworker.grants.delete_all
      expect(names(tier: entry.tier)).not_to include(entry.tool_name)

      coworker.grants.create!(capability: entry.capability.to_s, approval_policy: "auto")
      expect(names(tier: entry.tier)).to include(entry.tool_name)
    end
  end

  it "offers interactive-only tools only for an interactive turn" do
    coworker.grants.create!(capability: "chat.message_owner", approval_policy: "auto")
    expect(names).not_to include("ask_user_question", "suggest_next_step")

    message = chat.messages.create!(role: "user", content: { "text" => "Hello" })
    chat.update_columns(current_turn_message_id: message.id, turn_in_flight: true)

    expect(names).to include("ask_user_question", "suggest_next_step")
  end

  it "checks out the home branch and withholds owner invocation credentials" do
    job = ChatTurnJob.new
    job.instance_variable_set(:@chat, chat)
    job.instance_variable_set(:@user_message, chat.messages.create!(role: "user", content: { "text" => "Hello" }))
    allow(ChatWorkspace).to receive(:ensure_root!).with(chat).and_return(Pathname("/tmp/coworker-root"))
    allow(ChatWorkspace).to receive(:ensure_branch_checkout!)
      .with(chat, repository, "coworkers/maya")
      .and_return(Pathname("/tmp/coworker-home"))

    expect(job.send(:ensure_workspace!)).to eq(Pathname("/tmp/coworker-home"))
    expect(job.send(:cli_invocation_env, double(provider: "claude"))).to eq({})
    expect(GithubClient).not_to receive(:for)
    yielded = nil
    job.send(:with_git_askpass_env) { |env| yielded = env }
    expect(yielded).to eq("GIT_TERMINAL_PROMPT" => "0")
  end
end
