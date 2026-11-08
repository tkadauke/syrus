require "rails_helper"

# Regression: a risky SSH command from an ordinary operator chat came back as a
# flat refusal -- "command requires explicit risky-command allowance" -- and
# created no approval request, so there was nothing for the operator to say yes
# to. SSH exec already declared the right capability descriptor and the broker
# already honoured an approved invocation; what was missing is that the
# operator-approval gate resolved descriptors only through McpToolRegistry,
# where a plugin-provided tool never appears. Ask, do not refuse.
RSpec.describe "operator approval for a risky SSH command" do
  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user:) }

  before do
    PluginRecord.find_by!(name: "credential_store").update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

  def ssh_tool
    Mcp::Sidecar.mcp_tools_for(CredentialStore::ChatToolSet, tier: :deferred, chat_session: chat_session)
      .find { |tool| tool.tool_name == "credential_store_ssh_exec" }
  end

  def call_ssh(command:)
    ssh_tool.call(
      server_context: { chat_session: chat_session },
      credential: "homeassistant", host: "ha.example.internal", user: "root", command: command
    )
  end

  def requests = ChatPendingAction.where(action: "authorized_tool_call").count

  it "asks the operator to approve a risky command instead of refusing it" do
    response = nil

    expect {
      response = call_ssh(command: 'sqlite3 -readonly /config/home-assistant_v2.db "select 1"')
    }.to change { requests }.by(1)

    text = response.content.first[:text]
    expect(text).to include("waiting")
    # The old dead end. The broker never got the chance to raise it.
    expect(text).not_to include("risky-command allowance")
  end

  it "binds the request to this exact invocation" do
    call_ssh(command: 'sqlite3 -readonly /config/home-assistant_v2.db "select 1"')
    request = ChatPendingAction.where(action: "authorized_tool_call").sole
    descriptor = CredentialStore::PermissionProvider.capability_descriptor("ssh.execute/risky@v1")

    expect(request.payload).to include("tool_name" => "credential_store_ssh_exec")
    # The fingerprint the broker will recompute from its own arguments has to
    # match the one the approval is issued against, or an approved command
    # would still be refused. connect_timeout is absent on one side and must
    # not count.
    expect(request.authorization_items.first.invocation_fingerprint).to eq(
      Permissions::InvocationFingerprint.call(
        descriptor: descriptor,
        arguments: { credential: "homeassistant", host: "ha.example.internal", user: "root",
                     command: 'sqlite3 -readonly /config/home-assistant_v2.db "select 1"' }
      )
    )
  end

  it "asks for a read-only command too, because the capability declares ask for both" do
    expect { call_ssh(command: "ha core info") }.to change { requests }.by(1)

    # Not a side effect of routing through the gate: both SSH operations are
    # registered with an ask default, so this is the declared policy being
    # honoured rather than invented. An operator who wants reads to run
    # unattended grants a rule for ssh.execute/read@v1; that is the knob, and
    # it is the same knob a coworker would use.
    %w[ssh.execute/read@v1 ssh.execute/risky@v1].each do |operation|
      expect(CredentialStore::PermissionProvider.capability_descriptor(operation).defaults.values.uniq).to eq([ :ask ])
    end
  end

  it "records which operation the command classified as, not just the capability" do
    call_ssh(command: "ha core info")
    read_item = ChatPendingAction.where(action: "authorized_tool_call").sole.authorization_items.first

    expect(read_item.operation).to eq("ssh.execute/read")

    ChatPendingAction.delete_all
    call_ssh(command: "rm -rf /tmp/whatever")
    risky_item = ChatPendingAction.where(action: "authorized_tool_call").sole.authorization_items.first

    expect(risky_item.operation).to eq("ssh.execute/risky")
  end
end
