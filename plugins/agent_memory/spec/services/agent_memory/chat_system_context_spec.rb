require "rails_helper"

# What the memory store actually puts in front of a chat agent: the pinned
# context lines, their ranking, and the byte budget. Core renders whatever
# `Syrus::Memory` hands back -- these examples are about what this store
# hands back through a real `Prompts::ChatSystem`.
RSpec.describe Prompts::ChatSystem, "agent memory context" do
  let(:repo) { repository(owner: "acme", name: "widgets") }

  def pinned_context_body(output)
    output[/Pinned context:\n(?<body>(?:  - .*\n)+)/, :body].rstrip
  end

  it "renders own global memories near the top" do
    chat = ChatSession.create!(user: repo.user, repository: repo)
    AgentMemory::Entry.create!(
      user: repo.user,
      kind: "user_pref",
      scope: "global",
      content: "Prefers concise planning notes."
    )

    out = described_class.new(repository: repo, chat_session: chat).to_s

    expect(out).to include("Pinned context:")
    expect(out).to include("- [user_pref] Prefers concise planning notes.")
    expect(out.index("Pinned context:")).to be < out.index("Your environment:")
  end

  it "renders own repository memories for attached repositories" do
    chat = ChatSession.create!(user: repo.user, repository: repo)
    attached_repo = Factories.repository(user: repo.user, owner: "Acme", name: "Forum")
    unattached_repo = Factories.repository(user: repo.user, owner: "Acme", name: "Backlog")
    chat.chat_attachments.create!(attachable: attached_repo)
    AgentMemory::Entry.create!(
      user: repo.user,
      kind: "project_fact",
      scope: "repository",
      scope_id: attached_repo.id,
      content: "Forum deploys from trunk."
    )
    AgentMemory::Entry.create!(
      user: repo.user,
      kind: "project_fact",
      scope: "repository",
      scope_id: unattached_repo.id,
      content: "Backlog has a private deploy rule."
    )

    out = described_class.new(repository: repo, chat_session: chat).to_s

    expect(out).to include("- [project_fact/#{attached_repo.id}] Forum deploys from trunk.")
    expect(out).not_to include("Backlog has a private deploy rule.")
  end

  it "renders published repository memories from other users" do
    chat = ChatSession.create!(user: repo.user, repository: repo)
    other_user = Factories.user
    AgentMemory::Entry.create!(
      user: other_user,
      kind: "reference",
      scope: "repository",
      scope_id: repo.id,
      content: "Shared staging runbook is in the team drive.",
      published: true
    )

    out = described_class.new(repository: repo, chat_session: chat).to_s

    expect(out).to include("- [reference/#{repo.id}/shared] Shared staging runbook is in the team drive.")
  end

  it "omits unpublished repository memories from other users" do
    chat = ChatSession.create!(user: repo.user, repository: repo)
    other_user = Factories.user
    AgentMemory::Entry.create!(
      user: other_user,
      kind: "decision",
      scope: "repository",
      scope_id: repo.id,
      content: "Private unreconciled rollout note."
    )

    out = described_class.new(repository: repo, chat_session: chat).to_s

    expect(out).to include("Pinned context:\n  - (none)")
    expect(out).not_to include("Private unreconciled rollout note.")
  end

  it "ranks high-confidence memories before low-confidence ones" do
    chat = ChatSession.create!(user: repo.user, repository: repo)
    AgentMemory::Entry.create!(user: repo.user, kind: "project_fact", scope: "global", content: "Low confidence fact.", confidence: 0.3)
    AgentMemory::Entry.create!(user: repo.user, kind: "project_fact", scope: "global", content: "High confidence fact.", confidence: 0.9)

    out = described_class.new(repository: repo, chat_session: chat).to_s

    expect(out.index("High confidence fact.")).to be < out.index("Low confidence fact.")
  end

  it "ranks repository-scoped memories above global ones when a repository is attached" do
    chat = ChatSession.create!(user: repo.user, repository: repo)
    attached_repo = Factories.repository(user: repo.user)
    chat.chat_attachments.create!(attachable: attached_repo)
    AgentMemory::Entry.create!(user: repo.user, kind: "project_fact", scope: "global", content: "Global fact.")
    AgentMemory::Entry.create!(user: repo.user, kind: "project_fact", scope: "repository", scope_id: attached_repo.id, content: "Repository-scoped fact.")

    out = described_class.new(repository: repo, chat_session: chat).to_s

    expect(out.index("Repository-scoped fact.")).to be < out.index("Global fact.")
  end

  it "caps rendered memory text by byte budget" do
    chat = ChatSession.create!(user: repo.user, repository: repo)
    AgentMemory::Entry.create!(
      user: repo.user,
      kind: "project_fact",
      scope: "repository",
      scope_id: repo.id,
      content: "é" * 2_000
    )

    out = described_class.new(repository: repo, chat_session: chat).to_s

    pinned = pinned_context_body(out)
    clipped = pinned.delete_prefix("  - ").delete_suffix("...")
    expect(clipped.bytesize).to be <= 2.kilobytes
    expect(pinned).to end_with("...")
  end

  it "reports how many visible memories were omitted after the byte budget is exhausted" do
    chat = ChatSession.create!(user: repo.user, repository: repo)
    4.times do |index|
      AgentMemory::Entry.create!(
        user: repo.user,
        kind: "project_fact",
        scope: "global",
        content: "Memory #{index} #{"A" * 1_890}"
      )
    end

    out = described_class.new(repository: repo, chat_session: chat).to_s

    expect(pinned_context_body(out)).to include("  - (2 more not shown — call list_memories to retrieve them)")
  end

  it "does not append an omitted-memory notice when all memories fit" do
    chat = ChatSession.create!(user: repo.user, repository: repo)
    AgentMemory::Entry.create!(
      user: repo.user,
      kind: "user_pref",
      scope: "global",
      content: "Prefers short answers."
    )
    AgentMemory::Entry.create!(
      user: repo.user,
      kind: "decision",
      scope: "global",
      content: "Use the current planning template."
    )

    out = described_class.new(repository: repo, chat_session: chat).to_s

    expect(pinned_context_body(out)).not_to include("more not shown")
  end

  it "does not append an omitted-memory notice when the final rendered memory is clipped" do
    chat = ChatSession.create!(user: repo.user, repository: repo)
    AgentMemory::Entry.create!(
      user: repo.user,
      kind: "project_fact",
      scope: "global",
      content: "A" * 1_900
    )
    AgentMemory::Entry.create!(
      user: repo.user,
      kind: "project_fact",
      scope: "global",
      content: "B" * 500
    )

    out = described_class.new(repository: repo, chat_session: chat).to_s
    pinned = pinned_context_body(out)

    expect(pinned).to end_with("...")
    expect(pinned).not_to include("more not shown")
  end
end
