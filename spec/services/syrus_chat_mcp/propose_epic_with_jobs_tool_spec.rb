require "rails_helper"

RSpec.describe SyrusChatMcp::ProposeEpicWithJobsTool do
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
