require "rails_helper"

RSpec.describe Prompts::ChatSystem, "memory preflight" do
  let(:repo) { repository(owner: "acme", name: "widgets") }
  let(:chat) { ChatSession.create!(user: repo.user, repository: repo) }

  it "requires a preflight naming the consequential categories and steps" do
    out = described_class.new(repository: repo, chat_session: chat).to_s.squish

    expect(out).to include("Memory preflight (required before consequential actions)")
    expect(out).to include("Job or Epic proposal", "scheduling unattended work",
                           "changing priority or dependencies", "administrative repair")
    expect(out).to include('list_memories(kind: "user_pref", limit: 100)', "search_memories(query)", "read_memory(memory_id)")
    expect(out).to include("do not perform the consequential mutation")
    expect(out).to include("do not need a memory search")
  end

  it "adds no memory section or preflight when no memory store is registered" do
    allow(Syrus::Memory).to receive(:chat_instructions).and_return("")
    out = described_class.new(repository: repo, chat_session: chat).to_s.squish

    expect(out).not_to include("## Memory", "Memory preflight", "list_memories", "search_memories")
  end

  it "leaves coworker workspace-memory instructions in place of the generic preflight" do
    coworker = Coworkers::Coworker.create!(
      owner_user: repo.user, name: "Maya", handle: "maya-preflight", workspace_repo: repo.remote_url
    )
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    scope = Syrus::EffectScope.new(label: "memory preflight coworker spec")
    Coworkers::ChatExtension.install_into(scope)

    out = described_class.new(repository: repo, chat_session: chat).to_s.squish

    expect(out).to include("Your workspace identity and `memory/**` files are your durable memory.")
    expect(out).not_to include("Memory preflight")
  ensure
    scope&.dispose
  end
end
