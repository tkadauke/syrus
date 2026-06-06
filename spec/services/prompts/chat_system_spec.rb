require "rails_helper"

RSpec.describe Prompts::ChatSystem do
  let(:repo) { repository(owner: "acme", name: "widgets") }

  it "interpolates the repository slug into the role framing" do
    out = described_class.new(repository: repo).to_s

    expect(out).to include(<<~TEXT.strip)
      You are an embedded research and planning assistant for the
      acme/widgets repository.
    TEXT
  end

  it "frames chat as planning and proposal drafting, not editing" do
    out = described_class.new(repository: repo).to_s

    expect(out).to include("draft\nSyrus Jobs — NOT to make code changes yourself.")
    expect(out).to match(/No\s+commit or push tool is available to you here\./)
    expect(out).to include("Recommend; don't decide.")
  end

  it "renders active repository notes near the top" do
    repo.repository_notes.create!(body: "Use the App credential path for this repo.", author: "operator")
    repo.repository_notes.create!(body: "Removed context.", author: "agent", removed_at: Time.current)

    out = described_class.new(repository: repo).to_s

    expect(out).to include("Pinned context:")
    expect(out).to include("- Use the App credential path for this repo.")
    expect(out).not_to include("Removed context.")
    expect(out.index("Pinned context:")).to be < out.index("Your environment:")
  end

  it "includes a compact environment snapshot with chat tool availability" do
    chat = ChatSession.create!(user: repo.user, repository: repo)

    out = described_class.new(repository: repo, chat_session: chat).to_s

    expect(out).to include("Agent environment snapshot:")
    expect(out).to include("Chat: ##{chat.id} scoped to acme/widgets")
    expect(out).to include("no commit, push, or PR-opening tool is available in chat")
    expect(out).to include("live Syrus state: list_jobs, read_job, read_pr")
    expect(out.index("Agent environment snapshot:")).to be < out.index("Attached context:")
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

  it "caps rendered repository note body text" do
    repo.repository_notes.create!(body: "x" * 2_100, author: "operator")

    out = described_class.new(repository: repo).to_s

    # Match the pinned-context bullet list — runs of "  - …" lines
    # ending at the first blank line. Anchoring on the next section
    # header is brittle: the prompt has multiple sections, and any
    # one of them could land first.
    pinned = out[/Pinned context:\n(?<body>(?:  - .*\n)+)/, :body].rstrip
    expect(pinned.length).to be <= 2.kilobytes + 10
    expect(pinned).to end_with("...")
  end

  it "captures the workspace expectations that should not regress" do
    out = described_class.new(repository: repo).to_s

    expect(out).to include("The workspace persists across turns.")
    expect(out).to include("Use `attach_repository(slug)` whenever you need to look at")
    expect(out).to include("switch back to the default branch when you're done")
    expect(out).to match(/Feel free to run\s+`git fetch` or `git pull --ff-only`/)
    expect(out).to match(/Use `repo_info` when\s+you want a quick repository status summary\./)
  end

  it "supports top-level chats that do not start with a repository" do
    out = described_class.new(repository: nil).to_s

    expect(out).to include("embedded research and planning assistant for the\nchat workspace")
    expect(out).to include("Use `attach_repository(slug)`")
    expect(out).to include("Pinned context:\n  - (none)")
  end

  it "captures the durable chat artifact contract that should not regress" do
    out = described_class.new(repository: repo).to_s

    expect(out).to include("The durable products of this session are proposals")
    expect(out).to include("`propose_epic`")
    expect(out).to include("`propose_job`")
    expect(out).to include("`propose_issue`")
    expect(out).to match(/Recurring schedules require\s+operator confirmation/)
    expect(out).to include("Use unique, stable, descriptive `slug`s")
    expect(out).to include("Express dependencies between proposals when they exist")
    expect(out).to include("Default `kind: \"syrus_issue\"`")
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
  end

  it "captures the helpfulness guidance that should not regress" do
    out = described_class.new(repository: repo).to_s

    expect(out).to include("Recommend; don't decide.")
    expect(out).to include("Cite specific files and line numbers.")
    expect(out).to include("Inspect prior Jobs (`list_jobs`, `read_job`)")
  end
end
