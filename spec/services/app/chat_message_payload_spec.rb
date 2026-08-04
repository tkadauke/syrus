require "rails_helper"

RSpec.describe App::ChatMessagePayload do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat) { ChatSession.create!(user: user, repository: repository) }

  it "extracts text from legacy flat assistant messages for the text field" do
    message = chat.messages.create!(role: "assistant", content: { "text" => "Hello legacy." })

    payload = described_class.messages([ message ], repository: repository).first

    expect(payload.fetch(:text)).to eq("Hello legacy.")
    expect(payload.fetch(:content)).to eq({ "text" => "Hello legacy." })
  end

  it "extracts text from canonical content-blocks assistant messages for the text field" do
    message = chat.messages.create!(role: "assistant", content: [
      { "type" => "thinking", "thinking" => "Let me think...", "signature" => "sig" },
      { "type" => "text", "text" => "Here is the answer." }
    ])

    payload = described_class.messages([ message ], repository: repository).first

    expect(payload.fetch(:text)).to eq("Here is the answer.")
    expect(payload.fetch(:content)).to be_an(Array)
  end

  it "returns empty text for canonical tool_use messages" do
    message = chat.messages.create!(role: "tool_use", tool_name: "Read",
                                    content: { "type" => "tool_use", "id" => "t1", "name" => "Read", "input" => {} })

    payload = described_class.messages([ message ], repository: repository).first

    expect(payload.fetch(:text)).to eq("")
  end

  it "includes stored chat message attachments" do
    attachment = { "name" => "diagram.png", "mime_type" => "image/png", "data" => "cGl4ZWxz" }
    message = chat.messages.create!(role: "user", content: { "text" => "Inspect this.", "attachments" => [ attachment ] })

    payload = described_class.messages([ message ], repository: repository).first

    expect(payload.fetch(:attachments)).to eq([ attachment ])
  end

  it "includes the message creation timestamp in ISO8601 format" do
    message = chat.messages.create!(role: "user", content: { "text" => "Inspect this." })

    payload = described_class.messages([ message ], repository: repository).first

    expect(payload.fetch(:created_at)).to eq(message.created_at.iso8601)
    expect(Time.iso8601(payload.fetch(:created_at))).to be_within(1.second).of(message.created_at)
  end

  it "returns materialized job details for a confirmed job proposal" do
    job = Factories.job_record(user: user, repository: repository, issue_title: "Add inspection tools", state: "open")
    proposal = chat.proposals.create!(
      repository: repository,
      job: job,
      kind: "job",
      state: "confirmed",
      slug: "inspection-tools",
      title: "Add inspection tools",
      body: "Inspect more."
    )
    message = chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Proposal confirmed." })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:proposal)

    expect(payload.fetch(:materialized)).to eq(
      kind: "job",
      job_id: job.id,
      job_title: "Add inspection tools",
      job_state: "open"
    )
  end

  it "returns materialized epic details and child jobs for a confirmed epic bundle" do
    epic = Factories.epic(user: user, repository: repository, title: "Chat-driven job feedback loop")
    parent = chat.proposals.create!(
      repository: repository,
      epic: epic,
      kind: "epic",
      state: "confirmed",
      slug: "feedback-loop",
      title: "Chat-driven job feedback loop",
      body: "Bundle the work."
    )
    child_job = Factories.job_record(user: user, repository: repository, issue_title: "Add trigger", state: "queued")
    chat.proposals.create!(
      repository: repository,
      parent_proposal: parent,
      job: child_job,
      kind: "job",
      state: "confirmed",
      slug: "add-trigger",
      title: "Add trigger",
      body: "Trigger it."
    )
    message = chat.messages.create!(role: "assistant", proposal: parent, content: { "text" => "Epic proposal confirmed." })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:proposal)

    expect(payload.fetch(:materialized)).to eq(
      kind: "epic",
      epic_id: epic.id,
      epic_title: "Chat-driven job feedback loop",
      child_jobs: [
        { job_id: child_job.id, title: "Add trigger" }
      ]
    )
  end

  it "includes inline pending action details with a job resource" do
    job = Factories.job_record(user: user, repository: repository, issue_title: "Inject memories into chat system prompt", state: "implemented")
    action = chat.pending_actions.create!(
      action: "cancel_job",
      requested_by: "agent",
      payload: { "job_id" => job.id }
    )
    message = chat.messages.create!(role: "assistant", pending_action: action, content: { "text" => "Cancel it?" })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:pending_action)

    expect(payload).to eq(
      id: action.id,
      action: "cancel_job",
      state: "pending",
      label: "Cancel #{job.slug}",
      detail: nil,
      app_confirm_path: "/api/v1/app/chats/#{chat.id}/pending_actions/#{action.id}/confirm",
      app_reject_path: "/api/v1/app/chats/#{chat.id}/pending_actions/#{action.id}/reject",
      resource_title: "Inject memories into chat system prompt",
      resource_url: "/jobs/#{job.id}"
    )
  end

  it "includes restack_epic pending action details without an attached repository" do
    admin = Factories.user(admin: true)
    epic = Factories.epic(user: admin, repository: Factories.repository(user: admin), title: "Repair topology")
    supervisor_chat = ChatSession.create!(user: admin)
    action = supervisor_chat.pending_actions.create!(
      action: "restack_epic",
      requested_by: "agent",
      reason: "Repair stale stack topology.",
      payload: { "epic_id" => epic.id, "strategy" => "dependency_topology" }
    )
    message = supervisor_chat.messages.create!(role: "assistant", pending_action: action, content: { "text" => "Restack it?" })

    payload = described_class.messages([ message ], repository: nil).first.fetch(:pending_action)

    expect(payload).to include(
      id: action.id,
      action: "restack_epic",
      label: "Restack Epic ##{epic.id}",
      reason: "Repair stale stack topology.",
      resource_title: "Repair topology",
      resource_url: "/epics/#{epic.id}"
    )
  end

  it "omits pending action resource fields when the referenced job is gone" do
    action = chat.pending_actions.create!(
      action: "cancel_job",
      requested_by: "agent",
      payload: { "job_id" => 999_999 }
    )
    message = chat.messages.create!(role: "assistant", pending_action: action, content: { "text" => "Cancel it?" })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:pending_action)

    expect(payload).to include(
      id: action.id,
      action: "cancel_job",
      label: "Cancel JOB-999999"
    )
    expect(payload).not_to have_key(:resource_title)
    expect(payload).not_to have_key(:resource_url)
  end

  it "includes inline pending action detail for chat feedback" do
    job = Factories.job_record(user: user, repository: repository, state: "implemented")
    action = chat.pending_actions.create!(
      action: "submit_chat_feedback",
      requested_by: "agent",
      payload: { "job_id" => job.id, "feedback" => "Please tighten this implementation." }
    )
    message = chat.messages.create!(role: "assistant", pending_action: action, content: { "text" => "Send feedback?" })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:pending_action)

    expect(payload.fetch(:detail)).to eq("Please tighten this implementation.")
  end

  it "includes inline pending action detail for recurring schedules" do
    action = chat.pending_actions.create!(
      action_type: "schedule_recurring",
      requested_by: "agent",
      payload: {
        "label" => "Nightly sweep",
        "cron_expression" => "15 2 * * *",
        "prompt" => "Review open issues and suggest cleanup."
      }
    )
    message = chat.messages.create!(role: "assistant", pending_action: action, content: { "text" => "Schedule it?" })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:pending_action)

    expect(payload.fetch(:detail)).to eq("Nightly sweep — 15 2 * * *\n\nReview open issues and suggest cleanup.")
  end

  it "returns dependency details for a proposal" do
    dependency = chat.proposals.create!(
      repository: repository,
      kind: "job",
      state: "confirmed",
      slug: "chat-search-fts5",
      title: "Chat full-text search via dedicated SQLite FTS5 database",
      body: "Add search."
    )
    dependent = chat.proposals.create!(
      repository: repository,
      kind: "job",
      state: "proposed",
      slug: "chat-search-ui",
      title: "Chat search UI",
      body: "Expose search."
    )
    ChatProposalDependency.create!(proposal: dependent, depends_on: dependency)
    dependency_message = chat.messages.create!(role: "assistant", proposal: dependency, content: { "text" => "Dependency proposed." })
    message = chat.messages.create!(role: "assistant", proposal: dependent, content: { "text" => "Dependent proposed." })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:proposal)

    expect(payload.fetch(:has_dependencies)).to be(true)
    expect(payload.fetch(:dependency_slugs)).to eq([ "chat-search-fts5" ])
    expect(payload.fetch(:dependencies)).to eq([
      {
        slug: "chat-search-fts5",
        title: "Chat full-text search via dedicated SQLite FTS5 database",
        state: "confirmed",
        confirmed: true,
        anchor_message_id: dependency_message.id,
        materialized_label: nil,
        materialized_path: nil
      }
    ])
  end

  it "returns Epic proposal slug dependencies with unresolved and resolved labels" do
    resolved_epic = Factories.epic(user: user, repository: repository)
    proposal = chat.proposals.create!(
      repository: repository,
      kind: "epic",
      state: "proposed",
      slug: "dependent-epic",
      title: "Dependent Epic",
      body: "Wait for upstream work.",
      epic_depends_on_tokens: JSON.generate([ "foundation-epic", "epic:#{resolved_epic.id}" ])
    )
    message = chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Proposal created." })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:proposal)

    expect(payload.fetch(:has_dependencies)).to be(true)
    expect(payload.fetch(:dependency_slugs)).to eq([ "foundation-epic", "epic:#{resolved_epic.id}" ])
    expect(payload.fetch(:dependencies)).to include(
      {
        slug: "foundation-epic",
        title: "foundation-epic",
        display_label: "foundation-epic",
        state: "unresolved",
        confirmed: false,
        anchor_message_id: nil,
        materialized_path: nil
      },
      {
        slug: "epic:#{resolved_epic.id}",
        title: resolved_epic.slug,
        display_label: resolved_epic.slug,
        state: resolved_epic.state,
        confirmed: true,
        anchor_message_id: nil,
        materialized_path: "/epics/#{resolved_epic.id}"
      }
    )
  end

  it "returns sibling and cross-card dependency details for Epic child proposals" do
    epic = chat.proposals.create!(
      repository: repository,
      kind: "epic",
      state: "proposed",
      slug: "epic-card",
      title: "Epic card",
      body: "Bundle work."
    )
    sibling = chat.proposals.create!(
      repository: repository,
      parent_proposal: epic,
      kind: "job",
      slug: "schema",
      title: "Schema",
      body: "Persist it."
    )
    cross_card = chat.proposals.create!(
      repository: repository,
      kind: "job",
      state: "confirmed",
      slug: "upstream-job",
      title: "Upstream",
      body: "Do this first.",
      job: Factories.job_record(user: user, repository: repository)
    )
    child = chat.proposals.create!(
      repository: repository,
      parent_proposal: epic,
      kind: "job",
      slug: "ui",
      title: "UI",
      body: "Render it."
    )
    ChatProposalDependency.create!(proposal: child, depends_on: sibling)
    ChatProposalDependency.create!(proposal: child, depends_on: cross_card)
    message = chat.messages.create!(role: "assistant", proposal: epic, content: { "text" => "Proposal created." })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:proposal)
    ui_payload = payload.fetch(:children).find { |candidate| candidate.fetch(:slug) == "ui" }

    expect(ui_payload.fetch(:dependency_details)).to contain_exactly(
      include(slug: "schema", scope: "sibling", materialized_label: nil, materialized_path: nil),
      include(slug: "upstream-job", scope: "cross_card", materialized_label: "#{cross_card.job.slug}", materialized_path: "/jobs/#{cross_card.job.id}")
    )
  end

  it "uses the job title as label for submit_coding_changes pending actions" do
    action = chat.pending_actions.create!(
      action: "submit_coding_changes",
      requested_by: "agent",
      payload: {
        "repository_id" => repository.id,
        "branch" => "syrus/chat-42-handoff-7",
        "title" => "Add dark mode toggle",
        "description" => "Implemented a dark mode toggle in the settings panel."
      }
    )
    message = chat.messages.create!(role: "assistant", pending_action: action, content: { "text" => "Submit?" })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:pending_action)

    expect(payload.fetch(:label)).to eq("Add dark mode toggle")
  end

  it "includes branch, steps, and description in detail for submit_coding_changes pending actions" do
    action = chat.pending_actions.create!(
      action: "submit_coding_changes",
      requested_by: "agent",
      payload: {
        "repository_id" => repository.id,
        "branch" => "syrus/chat-42-handoff-7",
        "title" => "Add dark mode toggle",
        "description" => "Implemented a dark mode toggle in the settings panel."
      }
    )
    message = chat.messages.create!(role: "assistant", pending_action: action, content: { "text" => "Submit?" })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:pending_action)

    expect(payload.fetch(:detail)).to include("**Branch:** syrus/chat-42-handoff-7")
    expect(payload.fetch(:detail)).to include("Push branch to GitHub using server-side credentials")
    expect(payload.fetch(:detail)).to include("Create a new direct Job")
    expect(payload.fetch(:detail)).to include("`coding_handoff` workflow")
    expect(payload.fetch(:detail)).to include("---")
    expect(payload.fetch(:detail)).to include("Implemented a dark mode toggle in the settings panel.")
  end

  it "includes repository slug and path as resource fields for submit_coding_changes pending actions" do
    action = chat.pending_actions.create!(
      action: "submit_coding_changes",
      requested_by: "agent",
      payload: {
        "repository_id" => repository.id,
        "branch" => "syrus/chat-42-handoff-7",
        "title" => "Add dark mode toggle",
        "description" => "Implemented a dark mode toggle in the settings panel."
      }
    )
    message = chat.messages.create!(role: "assistant", pending_action: action, content: { "text" => "Submit?" })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:pending_action)

    expect(payload.fetch(:resource_title)).to eq("acme/widgets")
    expect(payload.fetch(:resource_url)).to eq("/repositories/#{repository.id}")
  end

  it "omits resource fields for submit_coding_changes when the repository is not found" do
    action = chat.pending_actions.create!(
      action: "submit_coding_changes",
      requested_by: "agent",
      payload: {
        "repository_id" => 999_999,
        "branch" => "syrus/chat-42-handoff-7",
        "title" => "Add dark mode toggle",
        "description" => "Implemented a dark mode toggle in the settings panel."
      }
    )
    message = chat.messages.create!(role: "assistant", pending_action: action, content: { "text" => "Submit?" })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:pending_action)

    expect(payload).not_to have_key(:resource_title)
    expect(payload).not_to have_key(:resource_url)
  end

  it "returns empty dependency details when a proposal has no dependencies" do
    proposal = chat.proposals.create!(
      repository: repository,
      kind: "job",
      state: "proposed",
      slug: "chat-search-ui",
      title: "Chat search UI",
      body: "Expose search."
    )
    message = chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Proposal created." })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:proposal)

    expect(payload.fetch(:has_dependencies)).to be(false)
    expect(payload.fetch(:dependencies)).to eq([])
  end

  it "includes depends_on_job_ids entries in visible_dependencies" do
    job = Factories.job_record(user: user, repository: repository, issue_title: "Build search index", state: "open")
    proposal = chat.proposals.create!(
      repository: repository,
      kind: "job",
      state: "proposed",
      slug: "chat-search-ui",
      title: "Chat search UI",
      body: "Expose search.",
      depends_on_job_ids: [ job.id ]
    )
    message = chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Proposal created." })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:proposal)

    expect(payload.fetch(:has_dependencies)).to be(true)
    expect(payload.fetch(:dependencies)).to include(
      hash_including(
        slug: job.slug,
        title: job.title,
        state: job.state,
        confirmed: true,
        anchor_message_id: nil,
        materialized_label: job.slug,
        materialized_path: "/jobs/#{job.id}"
      )
    )
  end

  it "includes depends_on_epic_ids entries in visible_dependencies" do
    epic = Factories.epic(user: user, repository: repository)
    proposal = chat.proposals.create!(
      repository: repository,
      kind: "job",
      state: "proposed",
      slug: "chat-epic-followup",
      title: "Epic follow-up job",
      body: "Do this after the epic.",
      depends_on_epic_ids: [ epic.id ]
    )
    message = chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Proposal created." })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:proposal)

    expect(payload.fetch(:has_dependencies)).to be(true)
    expect(payload.fetch(:dependencies)).to include(
      hash_including(
        slug: "epic:#{epic.id}",
        title: epic.slug,
        display_label: epic.slug,
        state: epic.state,
        confirmed: true,
        anchor_message_id: nil,
        materialized_path: "/epics/#{epic.id}"
      )
    )
  end

  it "still shows dependency_edges dependencies when depends_on_job_ids and depends_on_epic_ids are empty" do
    dependency = chat.proposals.create!(
      repository: repository,
      kind: "job",
      state: "confirmed",
      slug: "upstream-task",
      title: "Upstream task",
      body: "Do first."
    )
    dependent = chat.proposals.create!(
      repository: repository,
      kind: "job",
      state: "proposed",
      slug: "downstream-task",
      title: "Downstream task",
      body: "Do after.",
      depends_on_job_ids: [],
      depends_on_epic_ids: []
    )
    ChatProposalDependency.create!(proposal: dependent, depends_on: dependency)
    message = chat.messages.create!(role: "assistant", proposal: dependent, content: { "text" => "Proposal created." })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:proposal)

    expect(payload.fetch(:has_dependencies)).to be(true)
    expect(payload.fetch(:dependencies)).to include(hash_including(slug: "upstream-task"))
  end

  it "includes media_ids in proposal JSON" do
    snapshot = WhiteboardSnapshot.create!(
      chat_session: chat,
      name: "Board snapshot",
      scene_json: { "elements" => [], "appState" => {} },
      snapshot_kind: "manual",
      element_count: 0
    )
    proposal = chat.proposals.create!(
      repository: repository,
      kind: "job",
      state: "proposed",
      slug: "media-job",
      title: "Media job",
      body: "Has media.",
      media_ids: [ "snapshot:#{snapshot.id}" ]
    )
    message = chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Proposed." })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:proposal)

    expect(payload.fetch(:media_ids)).to eq([ "snapshot:#{snapshot.id}" ])
  end

  it "returns an empty array for media_ids when none are set" do
    proposal = chat.proposals.create!(
      repository: repository,
      kind: "job",
      state: "proposed",
      slug: "no-media-job",
      title: "No media job",
      body: "No media."
    )
    message = chat.messages.create!(role: "assistant", proposal: proposal, content: { "text" => "Proposed." })

    payload = described_class.messages([ message ], repository: repository).first.fetch(:proposal)

    expect(payload.fetch(:media_ids)).to eq([])
  end
end
