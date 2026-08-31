require "rails_helper"

RSpec.describe Mcp::Tools::ProposeEpicWithJobsTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: chat_session }
    )
  end

  def jsonrpc(server, method, id: 1, params: {})
    raw = server.handle_json({ jsonrpc: "2.0", id: id, method: method, params: params }.to_json)
    raw && JSON.parse(raw, symbolize_names: true)
  end

  def call_tool(arguments)
    jsonrpc(server, "tools/call", params: { name: "propose_epic_with_jobs", arguments: arguments })
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "creates one Epic proposal card with child Job rows and sibling dependencies" do
    prerequisite_epic = Factories.epic(user: user, repository: repository)
    prerequisite_job = Factories.job_record(user: user, repository: repository, issue_number: 7)

    response = call_tool(
      epic: {
        slug: "m3-proposals",
        title: "M3 proposals",
        description: "Make proposal review atomic.",
        target_repo: repository.slug,
        depends_on_job_ids: [ prerequisite_job.id ]
      },
      jobs: [
        {
          slug: "schema",
          target_repo: repository.slug,
          title: "Add proposal schema",
          description: "Persist the grouped proposal shape."
        },
        {
          slug: "ui",
          target_repo: repository.slug,
          title: "Render proposal card",
          description: "Show rows for child jobs.",
          depends_on_epic_ids: [ prerequisite_epic.id ],
          depends_on: [ "schema" ]
        }
      ]
    )

    proposal = chat_session.proposals.find_by!(slug: "m3-proposals")
    schema = chat_session.proposals.find_by!(slug: "schema")
    ui = chat_session.proposals.find_by!(slug: "ui")

    expect(response[:result][:isError]).to be_falsey
    expect(response_payload(response)).to include(slug: "m3-proposals", state: "proposed", kind: "epic")
    expect(proposal).to have_attributes(kind: "epic", repository: repository, title: "M3 proposals")
    expect(proposal.depends_on_job_ids).to eq([ prerequisite_job.id ])
    expect(proposal.child_proposals).to contain_exactly(schema, ui)
    expect(ui.depends_on_epic_ids).to eq([ prerequisite_epic.id ])
    expect(ui.dependencies).to contain_exactly(schema)
    expect(chat_session.messages.last).to have_attributes(role: "assistant", proposal: proposal)
  end

  it "does not attach active goal provenance to bundled Epic and child Job proposals by default" do
    ChatGoal.create!(
      chat_session: chat_session,
      user: user,
      repository: repository,
      prompt: "Draft a traceable bundle"
    )

    response = call_tool(
      epic: {
        slug: "ordinary-bundle",
        title: "Ordinary bundle",
        description: "No goal provenance.",
        target_repo: repository.slug
      },
      jobs: [
        {
          slug: "ordinary-child",
          target_repo: repository.slug,
          title: "Ordinary child",
          description: "No child provenance."
        }
      ]
    )

    payload = response_payload(response)
    proposal = chat_session.proposals.find_by!(slug: "ordinary-bundle")
    child = chat_session.proposals.find_by!(slug: "ordinary-child")
    expect(response[:result][:isError]).to be_falsey
    expect(proposal.chat_goal).to be_nil
    expect(child.chat_goal).to be_nil
    expect(payload[:goal_provenance]).to be_nil
    expect(payload[:child_jobs].sole[:goal_provenance]).to be_nil
  end

  it "returns active goal provenance when requested for bundled Epic and child Job proposals" do
    goal = ChatGoal.create!(
      chat_session: chat_session,
      user: user,
      repository: repository,
      prompt: "Draft a traceable bundle"
    )

    response = call_tool(
      epic: {
        slug: "traceable-bundle",
        title: "Traceable bundle",
        description: "Keep goal provenance.",
        target_repo: repository.slug
      },
      jobs: [
        {
          slug: "trace-child",
          target_repo: repository.slug,
          title: "Trace child",
          description: "Keep child provenance."
        }
      ],
      for_active_goal: true
    )

    payload = response_payload(response)
    proposal = chat_session.proposals.find_by!(slug: "traceable-bundle")
    child = chat_session.proposals.find_by!(slug: "trace-child")
    expect(response[:result][:isError]).to be_falsey
    expect(proposal.chat_goal).to eq(goal)
    expect(child.chat_goal).to eq(goal)
    expect(payload[:goal_provenance]).to include(chat_goal_id: goal.id)
    expect(payload[:child_jobs].sole[:goal_provenance]).to include(
      chat_goal_id: goal.id,
      prompt_snapshot: include(prompt: "Draft a traceable bundle")
    )
  end

  it "rejects active goal provenance when no goal is active" do
    response = call_tool(
      epic: {
        slug: "traceable-bundle",
        title: "Traceable bundle",
        description: "Keep goal provenance.",
        target_repo: repository.slug
      },
      jobs: [
        {
          slug: "trace-child",
          target_repo: repository.slug,
          title: "Trace child",
          description: "Keep child provenance."
        }
      ],
      for_active_goal: true
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("requires an active Chat Goal")
    expect(chat_session.proposals.find_by(slug: "traceable-bundle")).to be_nil
  end

  it "creates a grouped child Job proposal card for an existing Epic" do
    target_epic = Factories.epic(
      user: user,
      repository: repository,
      title: "PO-authored exports",
      description: "Initial product framing.",
      state: "backlog"
    )

    response = call_tool(
      epic: {
        slug: "exports-elaboration",
        epic_id: target_epic.id
      },
      jobs: [
        {
          slug: "export-schema",
          title: "Add export schema",
          description: "Persist export requests."
        },
        {
          slug: "export-ui",
          title: "Add export UI",
          description: "Let operators request exports.",
          depends_on: [ "export-schema" ]
        }
      ]
    )

    proposal = chat_session.proposals.find_by!(slug: "exports-elaboration")
    ui = chat_session.proposals.find_by!(slug: "export-ui")

    expect(response[:result][:isError]).to be_falsey
    expect(response_payload(response)).to include(target_epic: include(id: target_epic.id, label: target_epic.slug))
    expect(proposal).to have_attributes(
      kind: "epic",
      repository: repository,
      target_epic: target_epic,
      title: "PO-authored exports",
      body: "Initial product framing."
    )
    expect(proposal.child_proposals.map(&:repository)).to all(eq(repository))
    expect(ui.dependencies.pluck(:slug)).to eq([ "export-schema" ])
  end

  it "rejects an empty jobs array and creates no proposal" do
    response = call_tool(
      epic: { slug: "no-children", title: "No children", description: "Framing only." },
      jobs: []
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("must include at least one child Job")
    expect(chat_session.proposals).to be_empty
  end

  it "rejects existing Epics outside the chat user's scope" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user)
    foreign_epic = Factories.epic(user: other_user, repository: other_repo)

    response = call_tool(
      epic: { slug: "foreign", epic_id: foreign_epic.id },
      jobs: [
        { slug: "child", target_repo: repository.slug, title: "Child", description: "Build it." }
      ]
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("unknown epic_id")
    expect(chat_session.proposals.count).to eq(0)
  end

  it "rejects a done Epic and creates no proposals" do
    done_epic = Factories.epic(user: user, repository: repository, state: "done")

    response = call_tool(
      epic: { slug: "add-to-done", epic_id: done_epic.id },
      jobs: [
        { slug: "child", title: "Child", description: "Build it." }
      ]
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("Epic #{done_epic.id} is done")
    expect(response[:result][:content].first[:text]).to include("cannot propose a Job into a closed Epic")
    expect(chat_session.proposals.count).to eq(0)
  end

  it "rejects an archived Epic and creates no proposals" do
    archived_epic = Factories.epic(user: user, repository: repository, state: "archived")

    response = call_tool(
      epic: { slug: "add-to-archived", epic_id: archived_epic.id },
      jobs: [
        { slug: "child", title: "Child", description: "Build it." }
      ]
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("Epic #{archived_epic.id} is archived")
    expect(response[:result][:content].first[:text]).to include("cannot propose a Job into a closed Epic")
    expect(chat_session.proposals.count).to eq(0)
  end

  it "accepts an in_progress Epic and creates proposals" do
    in_progress_epic = Factories.epic(user: user, repository: repository, state: "in_progress", title: "Active work", description: "Work in flight.")

    response = call_tool(
      epic: { slug: "add-to-in-progress", epic_id: in_progress_epic.id },
      jobs: [
        { slug: "child-job", title: "Child Job", description: "Build it." }
      ]
    )

    expect(response[:result][:isError]).to be_falsey
    proposal = chat_session.proposals.find_by!(slug: "add-to-in-progress")
    expect(proposal.target_epic).to eq(in_progress_epic)
  end

  it "stores cross-card Job proposal dependencies on child Jobs" do
    prerequisite = chat_session.proposals.create!(
      repository: repository,
      slug: "upstream-job",
      title: "Upstream",
      body: "Do this first.",
      kind: "job"
    )

    response = call_tool(
      epic: {
        slug: "m3-proposals",
        title: "M3 proposals",
        description: "Make proposal review atomic.",
        target_repo: repository.slug
      },
      jobs: [
        {
          slug: "ui",
          target_repo: repository.slug,
          title: "Render proposal card",
          description: "Show rows for child jobs.",
          depends_on: [ "upstream-job" ]
        }
      ]
    )

    ui = chat_session.proposals.find_by!(slug: "ui")

    expect(response[:result][:isError]).to be_falsey
    expect(ui.dependencies).to contain_exactly(prerequisite)
  end

  it "rejects cross-card Job proposal dependencies that already closed unsuccessfully" do
    prerequisite = chat_session.proposals.create!(
      repository: repository,
      slug: "upstream-job",
      title: "Upstream",
      body: "Do this first.",
      kind: "job",
      job: Factories.job_record(user: user, repository: repository, issue_number: 7, state: "closed", closure_reason: "cancelled")
    )

    response = call_tool(
      epic: {
        slug: "m3-proposals",
        title: "M3 proposals",
        description: "Make proposal review atomic.",
        target_repo: repository.slug
      },
      jobs: [
        {
          slug: "ui",
          target_repo: repository.slug,
          title: "Render proposal card",
          description: "Show rows for child jobs.",
          depends_on: [ "upstream-job" ]
        }
      ]
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include(
      "Cannot depend on #{prerequisite.job.slug} because it is closed as cancelled and will not satisfy dependencies."
    )
    expect(chat_session.proposals.where(slug: "m3-proposals")).to be_empty
  end

  it "rejects unknown cross-entity dependencies without creating proposals" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user)
    foreign_job = Factories.job_record(user: other_user, repository: other_repo)

    response = call_tool(
      epic: { slug: "epic", title: "Epic", description: "Desc.", target_repo: repository.slug, depends_on_job_ids: [ foreign_job.id ] },
      jobs: [
        { slug: "ui", target_repo: repository.slug, title: "UI", description: "Build it.", depends_on_epic_ids: [ 123_456 ] }
      ]
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("unknown epic depends_on_job_ids")
    expect(chat_session.proposals.count).to eq(0)
  end

  it "rejects existing Epic-level Job dependencies that are already closed unsuccessfully" do
    prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 7)
    prerequisite.update_columns(state: "closed", closure_reason: "cancelled", finished_at: Time.current)

    response = call_tool(
      epic: { slug: "epic", title: "Epic", description: "Desc.", target_repo: repository.slug, depends_on_job_ids: [ prerequisite.id ] },
      jobs: [
        { slug: "ui", target_repo: repository.slug, title: "UI", description: "Build it." }
      ]
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include(
      "Cannot depend on #{prerequisite.slug} because it is closed as cancelled and will not satisfy dependencies."
    )
    expect(chat_session.proposals.count).to eq(0)
  end

  it "rejects existing child Job Epic dependencies that are already archived" do
    prerequisite = Factories.epic(user: user, repository: repository, state: "archived")

    response = call_tool(
      epic: { slug: "epic", title: "Epic", description: "Desc.", target_repo: repository.slug },
      jobs: [
        { slug: "ui", target_repo: repository.slug, title: "UI", description: "Build it.", depends_on_epic_ids: [ prerequisite.id ] }
      ]
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include(
      "Cannot depend on #{prerequisite.slug} because it is archived and will not satisfy dependencies."
    )
    expect(chat_session.proposals.count).to eq(0)
  end

  it "stores Epic-level proposal dependencies" do
    prerequisite = chat_session.proposals.create!(
      repository: repository,
      slug: "some-slug",
      title: "Prerequisite",
      body: "Do this first.",
      kind: "epic"
    )

    response = call_tool(
      epic: {
        slug: "dependent",
        title: "Dependent",
        description: "Depends on another proposal.",
        target_repo: repository.slug,
        depends_on: [ "some-slug" ]
      },
      jobs: [
        { slug: "child", target_repo: repository.slug, title: "Child", description: "Build it." }
      ]
    )

    proposal = chat_session.proposals.find_by!(slug: "dependent")

    expect(response[:result][:isError]).to be_falsey
    expect(proposal.dependencies).to contain_exactly(prerequisite)
    expect(proposal.epic_dependency_tokens).to eq([ "some-slug" ])
    expect(response_payload(response)).to include(depends_on: [ "some-slug" ])
  end

  it "stores Epic-level proposal dependencies from depends_on_proposal_slugs" do
    prerequisite = chat_session.proposals.create!(
      repository: repository,
      slug: "foundation-epic",
      title: "Foundation",
      body: "Do this first.",
      kind: "epic"
    )

    response = call_tool(
      epic: {
        slug: "dependent",
        title: "Dependent",
        description: "Depends on another proposal.",
        target_repo: repository.slug,
        depends_on_proposal_slugs: [ "foundation-epic" ]
      },
      jobs: [
        { slug: "child", target_repo: repository.slug, title: "Child", description: "Build it." }
      ]
    )

    proposal = chat_session.proposals.find_by!(slug: "dependent")

    expect(response[:result][:isError]).to be_falsey
    expect(proposal.dependencies).to contain_exactly(prerequisite)
    expect(proposal.epic_dependency_tokens).to eq([ "foundation-epic" ])
    expect(response_payload(response)).to include(depends_on_proposal_slugs: [ "foundation-epic" ])
  end


  it "stores string-encoded confirmed Epic dependencies" do
    prerequisite = Factories.epic(user: user, repository: repository)

    response = call_tool(
      epic: {
        slug: "dependent",
        title: "Dependent",
        description: "Depends on a confirmed Epic.",
        target_repo: repository.slug,
        depends_on: [ "epic:#{prerequisite.id}" ]
      },
      jobs: [
        { slug: "child", target_repo: repository.slug, title: "Child", description: "Build it." }
      ]
    )

    proposal = chat_session.proposals.find_by!(slug: "dependent")

    expect(response[:result][:isError]).to be_falsey
    expect(proposal.dependencies).to be_empty
    expect(proposal.epic_dependency_tokens).to eq([ "epic:#{prerequisite.id}" ])
  end

  it "rejects string-encoded confirmed Epic dependencies that are already archived" do
    prerequisite = Factories.epic(user: user, repository: repository, state: "archived")

    response = call_tool(
      epic: {
        slug: "dependent",
        title: "Dependent",
        description: "Depends on a confirmed Epic.",
        target_repo: repository.slug,
        depends_on: [ "epic:#{prerequisite.id}" ]
      },
      jobs: [
        { slug: "child", target_repo: repository.slug, title: "Child", description: "Build it." }
      ]
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include(
      "Cannot depend on #{prerequisite.slug} because it is archived and will not satisfy dependencies."
    )
    expect(chat_session.proposals.count).to eq(0)
  end

  it "rejects unknown sibling dependencies without creating proposals" do
    response = call_tool(
      epic: { slug: "epic", title: "Epic", description: "Desc.", target_repo: repository.slug },
      jobs: [
        { slug: "ui", target_repo: repository.slug, title: "UI", description: "Build it.", depends_on: [ "missing" ] }
      ]
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to match(/unknown depends_on slug/)
    expect(chat_session.proposals.count).to eq(0)
  end

  it "rejects unknown Epic-level proposal dependencies" do
    response = call_tool(
      epic: { slug: "epic", title: "Epic", description: "Desc.", target_repo: repository.slug, depends_on: [ "missing" ] },
      jobs: [
        { slug: "ui", target_repo: repository.slug, title: "UI", description: "Build it." }
      ]
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to match(/unknown depends_on slug/)
    expect(chat_session.proposals.count).to eq(0)
  end

  it "rejects archived target repositories without creating hidden proposals" do
    archived = Factories.repository(user: user, owner: "old", name: "archive")
    archived.archive!

    response = call_tool(
      epic: { slug: "epic", title: "Epic", description: "Desc.", target_repo: archived.slug },
      jobs: [
        { slug: "ui", target_repo: archived.slug, title: "UI", description: "Build it." }
      ]
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("unknown epic target_repo")
    expect(chat_session.proposals.count).to eq(0)
  end

  it "rejects dependency cycles before persisting anything" do
    response = call_tool(
      epic: { slug: "epic", title: "Epic", description: "Desc.", target_repo: repository.slug },
      jobs: [
        { slug: "a", target_repo: repository.slug, title: "A", description: "A.", depends_on: [ "b" ] },
        { slug: "b", target_repo: repository.slug, title: "B", description: "B.", depends_on: [ "a" ] }
      ]
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to match(/cycle/)
    expect(chat_session.proposals.count).to eq(0)
  end

  it "rejects fan-in child dependency graphs before creating any proposals" do
    response = call_tool(
      epic: { slug: "epic", title: "Epic", description: "Desc.", target_repo: repository.slug },
      jobs: [
        { slug: "left", target_repo: repository.slug, title: "Left", description: "Left." },
        { slug: "right", target_repo: repository.slug, title: "Right", description: "Right." },
        { slug: "merge", target_repo: repository.slug, title: "Merge", description: "Merge.", depends_on: [ "left", "right" ] }
      ]
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to match(/single chain.*left, right/)
    expect(chat_session.proposals.count).to eq(0)
  end

  it "rejects fan-out child dependency graphs before creating any proposals" do
    response = call_tool(
      epic: { slug: "epic", title: "Epic", description: "Desc.", target_repo: repository.slug },
      jobs: [
        { slug: "root", target_repo: repository.slug, title: "Root", description: "Root." },
        { slug: "left", target_repo: repository.slug, title: "Left", description: "Left.", depends_on: [ "root" ] },
        { slug: "right", target_repo: repository.slug, title: "Right", description: "Right.", depends_on: [ "root" ] }
      ]
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to match(/single chain.*left, right/)
    expect(chat_session.proposals.count).to eq(0)
  end

  it "rejects multiple root and leaf child graphs before creating any proposals" do
    response = call_tool(
      epic: { slug: "epic", title: "Epic", description: "Desc.", target_repo: repository.slug },
      jobs: [
        { slug: "first", target_repo: repository.slug, title: "First", description: "First." },
        { slug: "second", target_repo: repository.slug, title: "Second", description: "Second.", depends_on: [ "first" ] },
        { slug: "third", target_repo: repository.slug, title: "Third", description: "Third." },
        { slug: "fourth", target_repo: repository.slug, title: "Fourth", description: "Fourth.", depends_on: [ "third" ] }
      ]
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to match(/single chain.*first, third/)
    expect(chat_session.proposals.count).to eq(0)
  end

  it "rejects a nonlinear child graph even when adding to an existing Epic" do
    target_epic = Factories.epic(user: user, repository: repository, title: "Existing epic", description: "Existing description.")

    response = call_tool(
      epic: { slug: "add-nonlinear", epic_id: target_epic.id },
      jobs: [
        { slug: "root", target_repo: repository.slug, title: "Root", description: "Root." },
        { slug: "left", target_repo: repository.slug, title: "Left", description: "Left.", depends_on: [ "root" ] },
        { slug: "right", target_repo: repository.slug, title: "Right", description: "Right.", depends_on: [ "root" ] }
      ]
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to match(/single chain.*left, right/)
    expect(chat_session.proposals.count).to eq(0)
  end

  it "rejects a new child Job proposed into a non-empty existing Epic without chaining onto its existing Jobs" do
    target_epic = Factories.epic(user: user, repository: repository, title: "Existing epic", description: "Existing description.")
    existing_job = Factories.job_record(user: user, repository: repository, epic: target_epic, issue_number: 9)

    response = call_tool(
      epic: { slug: "add-orphan", epic_id: target_epic.id },
      jobs: [
        { slug: "orphan", target_repo: repository.slug, title: "Orphan", description: "Orphan." }
      ]
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to match(/single chain.*orphan, #{Regexp.escape(existing_job.slug)}/)
    expect(chat_session.proposals.count).to eq(0)
  end

  it "accepts a new child Job that chains onto a non-empty existing Epic via depends_on_job_ids" do
    target_epic = Factories.epic(user: user, repository: repository, title: "Existing epic", description: "Existing description.")
    existing_job = Factories.job_record(user: user, repository: repository, epic: target_epic, issue_number: 9)

    response = call_tool(
      epic: { slug: "add-chained", epic_id: target_epic.id },
      jobs: [
        { slug: "next-step", target_repo: repository.slug, title: "Next step", description: "Next.", depends_on_job_ids: [ existing_job.id ] }
      ]
    )

    expect(response[:result][:isError]).to be_falsey
    child = chat_session.proposals.find_by!(slug: "next-step")
    expect(child.depends_on_job_ids).to eq([ existing_job.id ])
  end

  it "rejects unknown job depends_on_job_ids without creating proposals" do
    response = call_tool(
      epic: { slug: "epic", title: "Epic", description: "Desc.", target_repo: repository.slug },
      jobs: [
        { slug: "ui", target_repo: repository.slug, title: "UI", description: "Build it.", depends_on_job_ids: [ 123_456 ] }
      ]
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("unknown job depends_on_job_ids")
    expect(chat_session.proposals.count).to eq(0)
  end

  it "rejects a child Job depends_on_job_ids target that is already closed unsuccessfully" do
    prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 7)
    prerequisite.update_columns(state: "closed", closure_reason: "cancelled", finished_at: Time.current)

    response = call_tool(
      epic: { slug: "epic", title: "Epic", description: "Desc.", target_repo: repository.slug },
      jobs: [
        { slug: "ui", target_repo: repository.slug, title: "UI", description: "Build it.", depends_on_job_ids: [ prerequisite.id ] }
      ]
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include(
      "Cannot depend on #{prerequisite.slug} because it is closed as cancelled and will not satisfy dependencies."
    )
    expect(chat_session.proposals.count).to eq(0)
  end

  it "accepts an unordered but valid three-job linear chain" do
    response = call_tool(
      epic: { slug: "epic", title: "Epic", description: "Desc.", target_repo: repository.slug },
      jobs: [
        { slug: "third", target_repo: repository.slug, title: "Third", description: "Third.", depends_on: [ "second" ] },
        { slug: "first", target_repo: repository.slug, title: "First", description: "First." },
        { slug: "second", target_repo: repository.slug, title: "Second", description: "Second.", depends_on: [ "first" ] }
      ]
    )

    expect(response[:result][:isError]).to be_falsey
    expect(chat_session.proposals.where(kind: "syrus_issue").count).to eq(3)
  end

  it "rejects a withdrawn epic slug without reviving the withdrawn proposal" do
    withdrawn = chat_session.proposals.create!(
      repository: repository,
      slug: "my-epic",
      title: "Old Epic",
      body: "Old description.",
      kind: "epic",
      state: "withdrawn"
    )

    response = call_tool(
      epic: { slug: "my-epic", title: "New Epic", description: "New description.", target_repo: repository.slug },
      jobs: [
        { slug: "job-1", target_repo: repository.slug, title: "Job", description: "Do it." }
      ]
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("already used and withdrawn")
    expect(withdrawn.reload).to be_withdrawn
    expect(chat_session.proposals.count).to eq(1)
  end

  it "rejects a withdrawn child job slug without reviving the withdrawn proposal" do
    withdrawn = chat_session.proposals.create!(
      repository: repository,
      slug: "old-job",
      title: "Old Job",
      body: "Old description.",
      kind: "syrus_issue",
      state: "withdrawn"
    )

    response = call_tool(
      epic: { slug: "new-epic", title: "New Epic", description: "New description.", target_repo: repository.slug },
      jobs: [
        { slug: "old-job", target_repo: repository.slug, title: "Job", description: "Do it." }
      ]
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("already used and withdrawn")
    expect(withdrawn.reload).to be_withdrawn
    expect(chat_session.proposals.where(slug: "new-epic").count).to eq(0)
  end

  it "stores media_ids on child job proposals when media is provided" do
    snapshot = WhiteboardSnapshot.create!(
      chat_session: chat_session,
      name: "Board snapshot",
      scene_json: { "elements" => [], "appState" => {} },
      snapshot_kind: "manual",
      element_count: 0
    )

    response = call_tool(
      epic: { slug: "media-epic", title: "Media Epic", description: "Attach media to jobs.", target_repo: repository.slug },
      jobs: [
        {
          slug: "media-job",
          target_repo: repository.slug,
          title: "Job with media",
          description: "Attach the whiteboard.",
          media: [ "snapshot:#{snapshot.id}" ]
        },
        {
          slug: "no-media-job",
          target_repo: repository.slug,
          title: "Job without media",
          description: "Nothing to attach.",
          depends_on: [ "media-job" ]
        }
      ]
    )

    expect(response[:result][:isError]).to be_falsey
    media_job = chat_session.proposals.find_by!(slug: "media-job")
    no_media_job = chat_session.proposals.find_by!(slug: "no-media-job")
    expect(media_job.media_ids).to eq([ "snapshot:#{snapshot.id}" ])
    expect(no_media_job.media_ids).to eq([])
  end

  describe "tool schema descriptions" do
    let(:schema) { described_class.input_schema.instance_variable_get(:@schema) }
    let(:tool_description) { described_class.description }

    it "explains that epic.depends_on blocks ALL child jobs" do
      epic_depends_on_desc = schema.fetch(:properties).fetch(:epic).fetch(:properties).fetch(:depends_on).fetch(:description)
      expect(epic_depends_on_desc).to include("Blocks ALL child jobs")
      expect(epic_depends_on_desc).to include("jobs[].depends_on_epic_ids")
    end

    it "explains that jobs[].depends_on_epic_ids is job-scoped not epic-scoped" do
      job_depends_on_epic_desc = schema.fetch(:properties).fetch(:jobs).fetch(:items).fetch(:properties).fetch(:depends_on_epic_ids).fetch(:description)
      expect(job_depends_on_epic_desc).to include("not the whole epic")
      expect(job_depends_on_epic_desc).to include("epic.depends_on")
    end

    it "includes behavioral guidance in the tool-level description" do
      expect(tool_description).to include("epic.depends_on")
      expect(tool_description).to include("jobs[].depends_on_epic_ids")
      expect(tool_description).to include("ALL child jobs")
    end

    it "explains the linear-chain constraint on child Jobs" do
      expect(tool_description).to match(/single linear dependency chain/i)
      expect(tool_description).to include("fan-out")
      expect(tool_description).to include("fan-in")

      job_depends_on_desc = schema.fetch(:properties).fetch(:jobs).fetch(:items).fetch(:properties).fetch(:depends_on).fetch(:description)
      expect(job_depends_on_desc).to match(/single linear chain/i)
    end
  end

  it "broadcasts an update_proposal event after creating the proposal" do
    allow(AppEvents).to receive(:broadcast)

    call_tool(
      epic: { slug: "the-epic", title: "Broadcast test", description: "Check broadcast.", target_repo: repository.slug },
      jobs: [ { slug: "job-a", target_repo: repository.slug, title: "Job A", description: "Do it." } ]
    )

    proposal = chat_session.proposals.find_by!(slug: "the-epic")
    expect(AppEvents).to have_received(:broadcast).with(
      user: user,
      type: "updated",
      resource: "chat",
      id: chat_session.id,
      changed: [ "proposal" ],
      payload: { action: "update_proposal", proposal_id: proposal.id }
    )
  end
end
