require "rails_helper"

# Every executable MCP tool -- core chat, coworker, workflow and agent-insight
# entries, every plugin tool set and every plugin permission provider -- must
# carry an intentional consequence classification: essential (never
# deniable), gated by a barrier effect it declares, or deniable for a named
# reason. See Permissions::ConsequenceClassification.
RSpec.describe "consequence classification of every MCP tool" do
  let(:validator) { Permissions::CapabilityRegistryValidator.for_application }
  let(:registrations) { validator.registrations }

  def registered(name, surface: nil, source: nil)
    registrations.select do |registration|
      registration.tool_name == name && (surface.nil? || registration.surface == surface) &&
        (source.nil? || registration.source.to_s.include?(source))
    end
  end

  it "inventories every surface and plugin contribution" do
    expect(registrations.map(&:surface).uniq).to include(
      :chat, :coworker, :workflow, :agent_insight, :mcp_tool_set, :chat_mcp_tool_set, :permission_provider
    )
    expect(registrations.size).to be > 400
  end

  it "classifies every registration on purpose" do
    unclassified = registrations.select do |registration|
      descriptor = registration.descriptor
      descriptor && !descriptor.essential? && descriptor.barrier_effects.empty? && descriptor.deniable_reason.nil?
    end

    expect(unclassified.map { |registration| "#{registration.source}/#{registration.surface}/#{registration.tool_name}" }).to be_empty
    expect(validator.findings).to be_empty
  end

  it "keeps registry `ungated` and descriptor `essential` in lockstep" do
    mismatched = registrations.select { |registration| registration.ungated && !registration.descriptor&.essential? }

    expect(mismatched.map(&:tool_name)).to be_empty
  end

  it "never lets an essential operation declare a barrier effect" do
    essential = registrations.filter_map(&:descriptor).select(&:essential?)

    expect(essential).not_to be_empty
    expect(essential.reject { |descriptor| descriptor.barrier_effects.empty? }.map(&:operation)).to be_empty
  end

  describe "pinned classifications" do
    it "keeps each core essential essential on the surface that lists it" do
      Permissions::ConsequenceClassification::ESSENTIAL.each do |surface, tools|
        tools.each do |tool|
          entries = registered(tool, surface:, source: "core")
          expect(entries).not_to be_empty, "#{surface}/#{tool} is classified but not registered"
          expect(entries.map { |entry| entry.descriptor.essential? }.uniq).to eq([ true ]), "#{surface}/#{tool}"
          expect(entries.map(&:ungated).uniq).to eq([ true ]), "#{surface}/#{tool}"
        end
      end
    end

    it "makes a user's private write_memory essential on chat and workflow surfaces" do
      %i[chat_mcp_tool_set mcp_tool_set].each do |surface|
        expect(registered("write_memory", surface:).map { |entry| entry.descriptor.essential? }).to all(be(true)), surface.to_s
      end
    end

    it "keeps the operations next to the essentials gated" do
      {
        "publish_memory" => :communication, "delete_memory" => :destructive,
        "send_chat_message" => :communication, "schedule_wakeup" => :persistent_autonomy,
        "spawn_chats" => :persistent_autonomy, "run_command" => :operator_host_access,
        "delegate_issue" => :external_write
      }.each do |tool, effect|
        entries = registered(tool)
        expect(entries).not_to be_empty, tool
        entries.each do |entry|
          expect(entry.descriptor).not_to be_essential, tool
          expect(entry.descriptor.barrier_effects).to include(effect), tool
        end
      end
    end

    it "classifies reset as destructive and dependency replacement as material control" do
      reset = registered("reset_job", source: "core").find { |entry| entry.surface == :chat }
      replacement = registered("replace_job_dependency", source: "core").find { |entry| entry.surface == :chat }

      expect(reset.descriptor.barrier_effects).to include(:destructive)
      expect(replacement.descriptor.deniable_reason).to eq(:material_control)
    end

    it "keeps deniable reads and Job edits deniable for their stated reasons" do
      {
        "read_run_transcript" => :confidential_cross_boundary, "get_job_diff" => :confidential_cross_boundary,
        "approve_job" => :material_control, "update_job" => :material_control,
        "grant_permission" => :privilege_change, "patch_workflow" => :autonomy_expansion
      }.each do |tool, reason|
        entry = registered(tool, source: "core").find { |candidate| candidate.surface != :coworker }
        expect(entry.descriptor).not_to be_essential, tool
        expect(entry.descriptor.deniable_reason).to eq(reason), tool
      end
    end

    it "gives coworkers the same essentials as chats" do
      chat_essentials = registrations.select { |entry| entry.surface == :chat && entry.descriptor&.essential? }.map(&:tool_name)
      coworker = registrations.select { |entry| entry.surface == :coworker }

      coworker.select { |entry| chat_essentials.include?(entry.tool_name) }.each do |entry|
        expect(entry.descriptor).to be_essential, entry.tool_name
      end
      expect(registered("list_jobs", surface: :coworker).sole.descriptor).to be_essential
      expect(registered("read_repository_file", surface: :coworker).sole.descriptor).to be_essential
    end
  end

  describe "permanent authority" do
    it "lets every ordinary operation be allowed forever" do
      capped = registrations.filter_map(&:descriptor).reject(&:essential?).select do |descriptor|
        descriptor.maximum_autonomy != :permanent
      end

      # Local mode keeps its own chat-scoped command rules.
      expect(capped.map(&:capability).uniq).to eq([ "syrus.local_mode@v1" ])
    end

    it "allows raw SQL, raw kubectl and SSH execution forever only per resource" do
      # Read from the providers directly: not every plugin is enabled in tests.
      floors = [
        MysqlDbBrowser::PermissionProvider.capability_descriptor("mysql.query/execute@v1"),
        K8sCluster::PermissionProvider.capability_descriptor("k8s.raw/execute@v1"),
        CredentialStore::PermissionProvider.capability_descriptor("ssh.execute/read@v1"),
        CredentialStore::PermissionProvider.capability_descriptor("ssh.execute/risky@v1")
      ]

      floors.each do |descriptor|
        expect(descriptor.breadth_ceilings).to eq(family: :invocation, tool: :invocation, resource: :permanent), descriptor.operation
      end
    end
  end
end
