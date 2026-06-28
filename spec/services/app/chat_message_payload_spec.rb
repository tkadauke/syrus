require "rails_helper"

RSpec.describe App::ChatMessagePayload do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat) { ChatSession.create!(user: user, repository: repository) }

  it "includes stored chat message attachments" do
    attachment = { "name" => "diagram.png", "mime_type" => "image/png", "data" => "cGl4ZWxz" }
    message = chat.messages.create!(role: "user", content: { "text" => "Inspect this.", "attachments" => [ attachment ] })

    payload = described_class.messages([ message ], repository: repository).first

    expect(payload.fetch(:attachments)).to eq([ attachment ])
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
      label: "Cancel JOB-#{job.id}",
      detail: nil,
      app_confirm_path: "/api/v1/app/chats/#{chat.id}/pending_actions/#{action.id}/confirm",
      app_reject_path: "/api/v1/app/chats/#{chat.id}/pending_actions/#{action.id}/reject",
      resource_title: "Inject memories into chat system prompt",
      resource_url: "/jobs/#{job.id}"
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
        title: resolved_epic.display_number,
        display_label: resolved_epic.display_number,
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
      include(slug: "upstream-job", scope: "cross_card", materialized_label: "JOB-#{cross_card.job.id}", materialized_path: "/jobs/#{cross_card.job.id}")
    )
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
end
