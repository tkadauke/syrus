require "rails_helper"

RSpec.describe SyrusChatMcp::AuthorizationSupport do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  let(:tool) do
    Class.new do
      extend SyrusChatMcp::AuthorizationSupport
    end
  end

  def with_context
    described_class.with_server_context({ chat_session: chat_session }) { yield }
  end

  it "finds jobs belonging to the current user" do
    job = Factories.job(repository: repository)

    expect(with_context { tool.find_job!(job.id) }).to eq(job)
  end

  it "raises AuthorizationError when find_job! sees another user's job" do
    other_user = Factories.user
    other_job = Factories.job(repository: Factories.repository(user: other_user))

    expect { with_context { tool.find_job!(other_job.id) } }
      .to raise_error(described_class::AuthorizationError, "job not found or not accessible")
  end

  it "returns a not_authorized tool error when registered tools raise AuthorizationError" do
    raising_tool = Class.new(MCP::Tool) do
      tool_name "raising_tool"
      input_schema(properties: {})

      class << self
        def call(server_context:)
          raise SyrusChatMcp::AuthorizationSupport::AuthorizationError, "blocked"
        end
      end
    end

    server = MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ SyrusChatMcp::Sidecar.authorize_tool(raising_tool) ],
      server_context: { chat_session: chat_session }
    )

    raw = server.handle_json({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: "raising_tool", arguments: {} }
    }.to_json)
    response = JSON.parse(raw, symbolize_names: true)
    payload = JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)

    expect(response[:result][:isError]).to be(true)
    expect(payload).to eq(error: "not_authorized")
  end
end
