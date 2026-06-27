require "rails_helper"

RSpec.describe Prompts::ChatSystem do
  let(:repo) { repository(owner: "acme", name: "widgets") }

  def pinned_context_body(output)
    output[/Pinned context:\n(?<body>(?:  - .*\n)+)/, :body].rstrip
  end

  it "interpolates the repository slug into the role framing" do
    out = described_class.new(repository: repo).to_s

    expect(out).to include(<<~TEXT.strip)
      You are Syrus Chat, an embedded research and planning assistant
      for the acme/widgets repository.
    TEXT
    expect(out).to include("answer as Syrus Chat attached to\nthis workspace or repository")
    expect(out).to include("do not\nintroduce yourself primarily as Claude")
  end

  it "appends the onboarding script only for onboarding chats" do
    standard = ChatSession.create!(user: repo.user, repository: repo)
    onboarding = ChatSession.create!(user: repo.user, repository: repo, onboarding: true)

    expect(described_class.new(repository: repo, chat_session: standard).to_s).not_to include("FIRST-RUN ONBOARDING")

    out = described_class.new(repository: repo, chat_session: onboarding).to_s
    expect(out).to include("FIRST-RUN ONBOARDING")
    expect(out).to include("propose_epic_with_jobs")
  end

  it "frames chat as planning and proposal drafting, not editing" do
    out = described_class.new(repository: repo).to_s

    expect(out).to include("draft\nSyrus Jobs — NOT to make code changes yourself.")
    expect(out).to match(/No\s+commit or push tool is available to you here\./)
    expect(out).to include("Attached repository checkouts are READ-ONLY for you.")
    expect(out).to include("/syrus-home/.syrus/chat-workspaces/*/repositories/")
    expect(out).to match(/must NEVER use\s+Write, Edit, or Bash to create, modify, delete, rename,\s+move, format, or generate files/)
    expect(out).to match(/propose a Syrus Job or Epic and wait\s+for the operator to confirm it\./)
    expect(out).to match(/You may write only to your own non-repository chat memory\s+directory/)
    expect(out).to include("Recommend; don't decide.")
  end

  it "instructs chat to use canonical Job and Epic reference formats" do
    out = described_class.new(repository: repo).to_s

    expect(out).to include("JOB-142 is stuck in landing because PR #98 has a base-branch")
    expect(out).to include("instead of just \"JOB-142 is open.\"")
    expect(out).to include("canonical formats: `JOB-<id>` for Jobs (e.g. JOB-1234) and")
    expect(out).to include("`EPIC-<id>` for Epics (e.g. EPIC-101)")
    expect(out).to match(/Never write "Job #142",\s+"job 142", or "J142" — use JOB-142\./)
  end

  it "renders own global memories near the top" do
    chat = ChatSession.create!(user: repo.user, repository: repo)
    ChatMemory.create!(
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

  it "renders chat-session pinned context ahead of repository notes" do
    chat = ChatSession.create!(
      user: repo.user,
      repository: repo,
      pinned_context: "Keep the migration compatible with MySQL."
    )
    repo.repository_notes.create!(body: "Prefer the App credential path for this repo.", author: "operator")

    out = described_class.new(repository: repo, chat_session: chat).to_s

    expect(out).to include("Pinned context:\n  - Keep the migration compatible with MySQL.\n  - Prefer the App credential path for this repo.")
  end

  it "explains when to write memories instead of proposing CLAUDE.md edits" do
    out = described_class.new(repository: repo).to_s

    expect(out).to include("Memory guidance:")
    expect(out).to include("Consult memories")
    expect(out).to include("preference alternatives")
    expect(out).to include("Do NOT save")
    expect(out).to include("Write memories for facts that emerged conversationally")
    expect(out).to include("Propose a CLAUDE.md edit when the fact is a durable team")
  end

  it "renders own repository memories for attached repositories" do
    chat = ChatSession.create!(user: repo.user, repository: repo)
    attached_repo = Factories.repository(user: repo.user, owner: "Acme", name: "Forum")
    unattached_repo = Factories.repository(user: repo.user, owner: "Acme", name: "Backlog")
    chat.chat_attachments.create!(attachable: attached_repo)
    ChatMemory.create!(
      user: repo.user,
      kind: "project_fact",
      scope: "repository",
      scope_id: attached_repo.id,
      content: "Forum deploys from trunk."
    )
    ChatMemory.create!(
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
    ChatMemory.create!(
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
    ChatMemory.create!(
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

  it "includes a compact environment snapshot with chat tool availability" do
    chat = ChatSession.create!(user: repo.user, repository: repo)

    out = described_class.new(repository: repo, chat_session: chat).to_s

    expect(out).to include("Agent environment snapshot:")
    expect(out).to include("Chat: ##{chat.id} scoped to acme/widgets")
    expect(out).to include("no commit, push, or PR-opening tool is available in chat")
    expect(out).to include("live Syrus state: list_chats, list_jobs, read_job, read_pr")
    expect(out.index("Agent environment snapshot:")).to be < out.index("Attached context:")
  end

  it "includes recent proposal activity when proposals were resolved recently" do
    chat = ChatSession.create!(user: repo.user, repository: repo)
    epic = Factories.epic(user: repo.user, repository: repo, title: "Chat-driven job feedback loop")
    epic_proposal = chat.proposals.create!(
      repository: repo,
      epic: epic,
      kind: "epic",
      state: "confirmed",
      slug: "feedback-loop",
      title: "Chat-driven job feedback loop",
      body: "Bundle it."
    )
    child_job = Factories.job_record(user: repo.user, repository: repo, issue_title: "Add trigger", state: "queued")
    chat.proposals.create!(
      repository: repo,
      parent_proposal: epic_proposal,
      job: child_job,
      kind: "job",
      state: "confirmed",
      slug: "add-trigger",
      title: "Add trigger",
      body: "Trigger it."
    )
    chat.proposals.create!(
      repository: repo,
      state: "rejected",
      slug: "some-title",
      title: "Some title",
      body: "No."
    )

    out = described_class.new(repository: repo, chat_session: chat).to_s

    expect(out).to include("Recent proposal activity:")
    expect(out).to include(%(- EPIC-#{epic.id} "Chat-driven job feedback loop" confirmed with jobs: JOB-#{child_job.id} "Add trigger" (proposal slug: feedback-loop)))
    expect(out).to include(%(- JOB-#{child_job.id} "Add trigger" confirmed (proposal slug: add-trigger)))
    expect(out).to include(%(- Proposal "Some title" was rejected (proposal slug: some-title)))
  end

  it "omits recent proposal activity when no proposals were resolved recently" do
    chat = ChatSession.create!(user: repo.user, repository: repo)
    old = chat.proposals.create!(
      repository: repo,
      state: "rejected",
      slug: "old-title",
      title: "Old title",
      body: "No."
    )
    old.update_columns(updated_at: 25.hours.ago)

    out = described_class.new(repository: repo, chat_session: chat).to_s

    expect(out).not_to include("Recent proposal activity:")
  end

  it "renders compact repository context for a single-repository chat" do
    chat = ChatSession.create!(user: repo.user, repository: repo)

    out = described_class.new(repository: repo, chat_session: chat).to_s

    expect(out).to include("Repository context:")
    expect(out).to include("Intended target repository: acme/widgets (default branch: main)")
    expect(out).to include("Attached repositories:\n    - acme/widgets (default branch: main)")
    expect(out).not_to include("Multiple repositories are attached")
    expect(out.index("Repository context:")).to be < out.index("Pinned context:")
  end

  it "normalizes attached repository slugs and warns before choosing among multiple repositories" do
    user = repo.user
    mixed_case = Factories.repository(user: user, owner: "Acme", name: "Forum", default_branch: "trunk")
    other = Factories.repository(user: user, owner: "Beta", name: "Roads", default_branch: "develop")
    chat = ChatSession.create!(user: user, repository: mixed_case)
    chat.chat_attachments.create!(attachable: other)

    out = described_class.new(repository: mixed_case, chat_session: chat).to_s

    expect(out).to include("Intended target repository: acme/forum (default branch: trunk)")
    expect(out).to include("- acme/forum (default branch: trunk)")
    expect(out).to include("- beta/roads (default branch: develop)")
    expect(out).to include("Multiple repositories are attached.")
    expect(out).to include("ask which checkout to inspect before using one")
  end

  it "renders supporting document hints without fetching document content" do
    file = Rack::Test::UploadedFile.new(
      StringIO.new("pdf"),
      "application/pdf",
      original_filename: "api.pdf"
    )
    pdf = repo.repository_documents.create!(
      user: repo.user,
      kind: "file",
      title: "API spec",
      file: file
    )
    google_doc = repo.repository_documents.create!(
      user: repo.user,
      kind: "google_doc",
      title: "Architecture notes",
      google_docs_url: "https://docs.google.com/document/d/abc/edit"
    )

    out = described_class.new(repository: repo).to_s

    expect(out).to include("Supporting documents available (use read_repo_document to fetch):")
    expect(out).to include("- [#{pdf.id}] API spec (PDF, 3 bytes)")
    expect(out).to include("- [#{google_doc.id}] Architecture notes (Google Doc)")
    expect(out.index("Supporting documents available")).to be < out.index("Your environment:")
  end

  it "renders attached Epics, Jobs, and documents as first-turn context" do
    chat = ChatSession.create!(user: repo.user, repository: repo)
    epic = Factories.epic(
      user: repo.user,
      repository: repo,
      title: "Drain the forum",
      description: "Move the puddle before the senators call it tradition."
    )
    child = Factories.job_record(
      user: repo.user,
      repository: repo,
      epic: epic,
      issue_title: "Install the humble channel",
      state: "queued"
    )
    attached_job = Factories.job_record(
      user: repo.user,
      repository: repo,
      issue_title: "Inventory existing drains",
      state: "implemented"
    )
    document = repo.repository_documents.create!(
      user: repo.user,
      kind: "google_doc",
      title: "Drainage notes",
      google_docs_url: "https://docs.google.com/document/d/drains/edit"
    )
    chat.chat_attachments.create!(attachable: epic)
    chat.chat_attachments.create!(attachable: attached_job)
    chat.chat_attachments.create!(attachable: document)

    out = described_class.new(repository: repo, chat_session: chat).to_s

    expect(out).to include("Attached context:")
    expect(out).to include("Epics:")
    expect(out).to include("#{epic.display_number}: Drain the forum")
    expect(out).to include("Move the puddle")
    expect(out).to include("Job ##{child.id}: Install the humble channel")
    expect(out).to include("Use `read_epic` with id #{epic.id}")
    expect(out).to include("Jobs:")
    expect(out).to include("Job ##{attached_job.id}: Inventory existing drains")
    expect(out).to include("Documents:")
    expect(out).to include("[#{document.id}] Drainage notes (Google Doc; use `read_repo_document`)")
    expect(out.index("Attached context:")).to be < out.index("What Syrus is")
  end

  it "caps rendered memory text by byte budget" do
    chat = ChatSession.create!(user: repo.user, repository: repo)
    ChatMemory.create!(
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
      ChatMemory.create!(
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
    ChatMemory.create!(
      user: repo.user,
      kind: "user_pref",
      scope: "global",
      content: "Prefers short answers."
    )
    ChatMemory.create!(
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
    ChatMemory.create!(
      user: repo.user,
      kind: "project_fact",
      scope: "global",
      content: "A" * 1_900
    )
    ChatMemory.create!(
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

  it "captures the workspace expectations that should not regress" do
    out = described_class.new(repository: repo).to_s

    expect(out).to include("The workspace persists across turns.")
    expect(out).to include("Use `attach_repository(slug)` whenever you need to look at")
    expect(out).to include("switch back to the default branch when you're done")
    expect(out).to match(/Feel free to run\s+`git fetch` or `git pull --ff-only`/)
    expect(out).to match(/Use `repo_info` when\s+you want a quick repository status summary\./)
  end

  it "gives the agent a fallback path when MCP tools are unavailable" do
    out = described_class.new(repository: repo).to_s

    expect(out).to include("MCP tools can be available, pending, or unavailable")
    expect(out).to match(/continue with ordinary read-only shell\s+inspection when possible/)
    expect(out).to match(/ask the operator to retry the\s+turn or check the chat sidecar health/)
    expect(out).to include("proposals, schedules, bookmarks, or whiteboard edits")
  end

  it "supports top-level chats that do not start with a repository" do
    chat = ChatSession.create!(user: repo.user)

    out = described_class.new(repository: nil, chat_session: chat).to_s

    expect(out).to include("Syrus Chat, an embedded research and planning assistant\nfor the chat workspace")
    expect(out).to include("Use `attach_repository(slug)`")
    expect(out).to include("Repository context:")
    expect(out).to include("No repository is attached yet.")
    expect(out).to include("Pinned context:\n  - (none)")
  end

  it "asks the operator to attach a repository from the plus menu when code context is needed" do
    chat = ChatSession.create!(user: repo.user)

    out = described_class.new(repository: nil, chat_session: chat).to_s

    expect(out).to include("No repository is currently attached. If the operator's request requires code context, ask them to attach one via the + menu.")
  end

  it "omits the plus-menu repository guidance when a repository is attached" do
    chat = ChatSession.create!(user: repo.user, repository: repo)

    out = described_class.new(repository: repo, chat_session: chat).to_s

    expect(out).not_to include("No repository is currently attached. If the operator's request requires code context, ask them to attach one via the + menu.")
  end

  it "captures the durable chat artifact contract that should not regress" do
    out = described_class.new(repository: repo).to_s

    expect(out).to include("The durable products of this session are proposals")
    expect(out).to include("`propose_epic`")
    expect(out).to include("`propose_job`")
    expect(out).not_to include("`propose_issue`")
    expect(out).to match(/Recurring schedules\s+require operator confirmation/)
    expect(out).to include("`propose_epic_with_jobs` requires unique, stable, descriptive")
    expect(out).to match(/always\s+use the slug, never the\s+numeric `id`/)
    expect(out).to match(/That `id` is an internal record identifier invisible to the\s+operator\./)
    expect(out).to include("A proposal's `id` is NOT the future JOB-<id> or EPIC-<id>")
    expect(out).to match(/Never write `JOB-\{proposal_id\}`\s+or `EPIC-\{proposal_id\}` using a proposal response's `id`\s+field\./)
    expect(out).to include("Express dependencies between proposals when they exist")
    expect(out).to include("Use `propose_job` for direct Syrus Job creation")
    expect(out).to include("Use `schedule_recurring(cron_expression, label, prompt)` only")
  end

  it "explains the Syrus domain model so the agent can reason about Epics, Jobs, and the lifecycle" do
    out = described_class.new(repository: repo).to_s

    expect(out).to include("What Syrus is")
    expect(out).to include("**Job** — one thread of work")
    expect(out).to include("**Epic** — a named grouping of Jobs")
    expect(out).to include("triaging → queued → open → implemented")
    expect(out).to include("propose_epic_with_jobs")
    expect(out).to include("When the operator hands you a planning document")
  end

  it "instructs the agent to bookmark topic shifts and epic origins" do
    out = described_class.new(repository: repo).to_s

    expect(out).to include("When the conversation shifts to a meaningfully new topic")
    expect(out).to include("`set_bookmark` first with a short noun-phrase label")
    expect(out).to include("use these as a table of contents in long threads.")
    expect(out).to include("Immediately before emitting a `propose_epic` card")
    expect(out).to include('`set_bookmark(label, kind: "epic_origin")`')
  end

  it "describes the shared whiteboard without snapshotting the full prompt" do
    out = described_class.new(repository: repo).to_s

    expect(out).to include("You have access to a shared whiteboard alongside this chat.")
    expect(out).to include("canvas wins for spatial relationships")
    expect(out).to include("Each shape\nyou create gets a stable id")
    expect(out).to include("`draw_line`")
    expect(out).to include("The scene\ncan include Excalidraw `elements`, `appState`, and `files`.")
    expect(out).to include("Reading the canvas via `read_scene` is cheap")
    expect(out).to include("`save_canvas` when the operator asks to preserve the current")
  end

  it "captures the helpfulness guidance that should not regress" do
    out = described_class.new(repository: repo).to_s

    expect(out).to include("Recommend; don't decide.")
    expect(out).to include("Cite specific files and line numbers.")
    expect(out).to include("Inspect prior Jobs (`list_jobs`, `read_job`)")
  end
end
