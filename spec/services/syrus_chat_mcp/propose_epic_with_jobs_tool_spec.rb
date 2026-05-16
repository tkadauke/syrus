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
    response = call_tool(
      epic: {
        slug: "m3-proposals",
        title: "M3 proposals",
        description: "Make proposal review atomic.",
        target_repo: repository.slug
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
    expect(proposal.child_proposals).to contain_exactly(schema, ui)
    expect(ui.dependencies).to contain_exactly(schema)
    expect(chat_session.messages.last).to have_attributes(role: "assistant", proposal: proposal)
  end

  it "rejects unknown sibling dependencies without creating proposals" do
    response = call_tool(
      epic: { slug: "epic", title: "Epic", description: "Desc.", target_repo: repository.slug },
      jobs: [
        { slug: "ui", target_repo: repository.slug, title: "UI", description: "Build it.", depends_on: [ "missing" ] }
      ]
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to match(/unknown sibling depends_on slug/)
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
end
