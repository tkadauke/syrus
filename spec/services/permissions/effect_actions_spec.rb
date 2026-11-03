require "rails_helper"

RSpec.describe Permissions::EffectActions do
  let(:chat_entries) { McpToolRegistry.entries(surface: :chat).index_by(&:tool_name) }

  it "maps every effect tool to an explicit, non-legacy chat registration" do
    described_class.tool_names.each do |tool_name|
      entry = chat_entries.fetch(tool_name)

      expect(entry).to have_attributes(explicit_descriptor: true, compatibility_descriptor: false)
      expect(entry.descriptor.classify({})).to include(confidence: :certain)
    end
  end

  it "keeps safe owned-artifact edits automatic" do
    %w[submit_artifact cancel_wakeup].each do |name|
      descriptor = chat_entries.fetch(name).descriptor

      expect(descriptor.defaults.values.uniq).to eq([ :allow ])
      expect(descriptor.classify({})[:risk]).to eq(:low)
    end
  end

  it "asks before persistent autonomy, communication, and document changes" do
    %w[schedule_wakeup send_chat_message spawn_chats create_repo_document delete_repo_document].each do |name|
      expect(chat_entries.fetch(name).descriptor.defaults.values.uniq).to eq([ :ask ])
    end
    expect(chat_entries.fetch("schedule_wakeup").descriptor.classify({})[:effects]).to include(:persistent_autonomy)
    expect(chat_entries.fetch("send_chat_message").descriptor.classify({})[:effects]).to include(:communication)
  end

  it "caps document deletion and chat spawning at exact-invocation authority" do
    %w[delete_repo_document spawn_chats].each do |name|
      descriptor = chat_entries.fetch(name).descriptor

      expect(descriptor.maximum_autonomy).to eq(:invocation)
      expect(descriptor.authority_durations).to eq([ :invocation ])
    end
    expect(chat_entries.fetch("delete_repo_document").descriptor.classify({})[:effects]).to include(:destructive)
  end

  it "uses unique operations and does not overlap other migrated sets" do
    operations = described_class.tool_names.map { |name| described_class.descriptor_for(name).operation }

    expect(operations.uniq.size).to eq(operations.size)
    expect(described_class.tool_names & (Permissions::JobLifecycle.tool_names + Permissions::OperationalActions.tool_names)).to be_empty
  end

  it "fingerprints exact arguments and ignores omitted optionals" do
    descriptor = described_class.descriptor_for("schedule_wakeup")

    expect(descriptor.normalize_fingerprint(prompt: "a", delay_minutes: 5, fire_at: nil)).to eq(descriptor.normalize_fingerprint("delay_minutes" => 5, "prompt" => "a"))
    expect(descriptor.normalize_fingerprint(prompt: "a")).not_to eq(descriptor.normalize_fingerprint(prompt: "b"))
  end

  it "raises no registry findings for these tools" do
    findings = Permissions::CapabilityRegistryValidator.for_application.findings
    mine = findings.select { |f| f.registrations.any? { |r| described_class.covers?(r.tool_name) } }

    expect(mine).to be_empty
  end

  describe "authorization dispatch" do
    it "installs the authorization hook on every migrated core tool" do
      described_class.tool_names.each do |name|
        tool = chat_entries.fetch(name).tool

        expect(tool.singleton_class).to be < Mcp::Tools::AuthorizationSupport::ToolDispatch
      end
    end

    it "returns a pending authorization instead of creating a wakeup when approval is required" do
      chat_session = ChatSession.create!(user: Factories.user)
      pending = MCP::Tool::Response.new([ { type: "text", text: { pending_action_id: 1 }.to_json } ])
      allow(Mcp::Tools::AuthorizationSupport).to receive(:pending_scheduled_authorization).and_return(nil)
      allow(Mcp::Tools::AuthorizationSupport).to receive(:pending_coworker_approval).and_return(pending)

      response = nil
      expect {
        response = Mcp::Tools::ScheduleWakeupTool.call(prompt: "check back", delay_minutes: 5, server_context: { chat_session: chat_session })
      }.not_to change(ChatWakeup, :count)
      expect(response).to equal(pending)
    end
  end
end
