require "rails_helper"

# A plugin-provided chat tool is not in McpToolRegistry: the sidecar builds it
# from a tool-set definition and hangs its descriptor on the tool itself. The
# operator-approval gate used to resolve descriptors only through the registry,
# so for every such tool it returned -- and returned *open*, letting the call
# run ungated -- while the coworker gate beside it refused the same call for
# want of a descriptor. Same tool, same capability, two different answers
# decided only by which kind of chat was asking.
RSpec.describe "operator approval for plugin-provided chat tools" do
  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user:) }
  let(:context) { McpToolContext.from_chat_session(chat_session) }
  let(:server_context) { { chat_session: chat_session } }

  def plugin_shaped_tool(name:, descriptor:)
    Class.new.tap do |klass|
      klass.define_singleton_method(:tool_name) { name }
      klass.define_singleton_method(:capability_descriptor) { descriptor } if descriptor
    end
  end

  def descriptor_for(name, mutation:)
    Permissions::CapabilityDescriptorAdapter.for_registry_entry(
      tool_name: name, capability: name.split("_").first, mutation: mutation,
      required_roles: [ context.role ]
    )
  end

  def gate(tool, arguments = { thing: 1 })
    Mcp::Tools::AuthorizationSupport.with_server_context(server_context) do
      Mcp::Tools::AuthorizationSupport.pending_actor_approval(tool, server_context, arguments)
    end
  end

  def request_count = ChatPendingAction.where(action: "authorized_tool_call").count

  it "asks before a mutating plugin tool runs, exactly as it would for a core tool" do
    tool = plugin_shaped_tool(name: "pluginwrite_thing", descriptor: descriptor_for("pluginwrite_thing", mutation: true))
    expect(McpToolRegistry.entry_for(tool)).to be_nil

    result = nil
    expect { result = gate(tool) }.to change { request_count }.by(1)

    expect(result).to be_present
    expect(result.content.first[:text]).to include("waiting")
  end

  it "leaves a read-only plugin tool alone, because its own descriptor allows it" do
    tool = plugin_shaped_tool(name: "pluginread_thing", descriptor: descriptor_for("pluginread_thing", mutation: false))

    result = nil
    expect { result = gate(tool) }.not_to change { request_count }

    expect(result).to be_nil
    # Allowed is not the same as skipped: the gate records the authorization so
    # the tool can still prove it ran under one.
    expect(server_context[:permission_authorization]).to include("tool_name" => "pluginread_thing")
  end

  it "stays out of the way of run-surface agents entirely" do
    # Visual review, graders and implement steps run with surface :run and
    # resolve authority through their own enforcement. The browser tools a
    # visual reviewer drives (evaluate, file_upload, drop) are invocation-
    # capped capabilities, so if this gate ever reached a run it would stop a
    # headless worker dead waiting for an operator who is not there.
    repository = Factories.repository(user:)
    run = Factories.job_with_run(user:, repository:).runs.first
    tool = plugin_shaped_tool(name: "browser_evaluate", descriptor: descriptor_for("browser_evaluate", mutation: true))
    run_server_context = { run: run }

    result = nil
    expect {
      result = Mcp::Tools::AuthorizationSupport.with_server_context(run_server_context) do
        Mcp::Tools::AuthorizationSupport.pending_actor_approval(tool, run_server_context, { script: "1+1" })
      end
    }.not_to change { request_count }

    expect(result).to be_nil
    expect(run_server_context[:permission_authorization]).to be_nil
  end

  it "skips a tool that declares no descriptor rather than inventing one" do
    tool = plugin_shaped_tool(name: "pluginundeclared_thing", descriptor: nil)

    expect { expect(gate(tool)).to be_nil }.not_to change { request_count }
  end
end
