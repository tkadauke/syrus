require "rails_helper"

# Interactive chat tool parity: every tool meaningful in an interactive chat is
# discoverable in planner, coding, local, and coworker chats unless a reviewed
# exception (reason code, explanation, owner, test) says the operation is
# semantically incoherent there. Discovery parity is separate from
# authorization: privileged tools stay shared and deny/confirm at call time.
RSpec.describe Mcp::ChatToolParity do
  let(:admin) { Factories.user(admin: true) }
  let(:member) { Factories.user }

  def coworker_names(user)
    context = McpToolContext.new(surface: :chat, role: AgentRole::COWORKER_CHAT, user: user)
    McpToolRegistry.tools_for_context(context, surface: :coworker).map { |tool| McpToolRegistry.tool_name_for(tool) }
  end

  it "has no unexplained differences between planner, coding, local, and coworker catalogs" do
    expect(described_class.report).to eq([])
  end

  it "fails on an unexplained omission or a stale exception" do
    stub_const("Mcp::ChatToolParity::PERMISSION_TOOLS", [])
    stub_const("Mcp::ChatToolParity::CORE_EXCEPTIONS", described_class::CORE_EXCEPTIONS.reject do |exception|
      exception.reason_code == "owner_permission_decision"
    end)

    expect(described_class.report).to include(a_string_matching(/grant_permission: unexplained absence from coworker/))
  end

  it "requires reason, explanation, owner, and test on every exception" do
    expect(described_class.exceptions).not_to be_empty
    described_class.exceptions.each do |exception|
      expect(described_class::REASON_CODES).to include(exception.reason_code)
      expect([ exception.explanation, exception.owner, exception.test_ref ]).to all(be_present)
      expect(Rails.root.join(exception.test_ref)).to exist
    end
    expect { described_class::ReviewedException.build(reason_code: "requires_coding_checkout", explanation: " ", owner: "x", test_ref: "y") }
      .to raise_error(ArgumentError, /missing explanation/)
  end

  it "keeps the reviewed exception set tiny" do
    reasons = described_class.exceptions.map(&:reason_code).uniq
    expect(reasons).to match_array(%w[
      owner_permission_decision workflow_run_bound_verdict coworker_sanitized_surface
      coworker_identity_lifecycle requires_coding_checkout requires_local_checkout evaluator_run_bound
    ])
  end

  describe "admin tools" do
    it "are discoverable for admin-owned coworkers and absent for non-admin owners" do
      expect(coworker_names(admin)).to include("admin_overview", "force_fail_job", "read_worker_health")
      expect(coworker_names(member)).not_to include("admin_overview", "force_fail_job")
    end
  end

  describe "owner-side and run-bound exceptions" do
    it "stay unavailable to coworkers" do
      names = coworker_names(admin)

      expect(names).not_to include(*described_class::PERMISSION_TOOLS, *described_class::WORKFLOW_VERDICT_TOOLS)
    end

    it "hide checkout-bound tools from coworkers" do
      expect(coworker_names(admin)).not_to include("run_command", "runtime_start", "submit_coding_changes", "write_file")
    end
  end

  describe "plugin chat tool sets" do
    let(:providers) { described_class.installed_chat_tool_sets }

    it "declare no removed boolean exclusion API and only complete exceptions" do
      providers.each do |provider|
        expect(provider).not_to respond_to(:coworker_excluded?)
        expect(provider).not_to respond_to(:coworker_specific_availability?)
        expect { Mcp::CoworkerToolExposure.plugin_provider?(provider) }.not_to raise_error
        expect { Mcp::CoworkerToolExposure.coworker_only_exception(provider) }.not_to raise_error

        definitions = Array(provider.tool_definitions(tier: nil))
        definitions.each do |definition|
          expect { Mcp::CoworkerToolExposure.plugin_definition?(definition, user: admin) }.not_to raise_error
        end
      end
    end

    it "has no unexplained plugin differences across planner, coding, local, and coworker catalogs" do
      expect(described_class.plugin_report(providers)).to eq([])
      expect(described_class.plugin_catalogs(providers).keys).to match_array(providers)
    end

    it "fails on an undeclared plugin omission in either direction" do
      provider = Class.new do
        def self.tool_definitions(tier:) = [ { name: "plugin_probe", admin_only: false } ]
        def self.coworker_exception = { reason_code: "requires_coding_checkout", explanation: "x", owner: "o", test_ref: "t" }
        def self.to_s = "ProbeSet"
      end
      expect(described_class.plugin_report([ provider ])).to eq([])

      silent = Class.new do
        def self.tool_definitions(tier:) = [ { name: "plugin_probe" } ]
        def self.coworker_only_surface = nil
        def self.to_s = "SilentSet"
      end
      allow(Mcp::CoworkerToolExposure).to receive(:plugin_definition?).and_return(false)
      expect(described_class.plugin_report([ silent ])).to include(a_string_matching(/plugin_probe: unexplained absence from coworker/))
    end

    it "includes legacy chat_mcp_tool_set registrations in the installed catalogs" do
      legacy = Class.new { def self.tool_definitions(tier:) = [] }
      manifest = Struct.new(:provides).new({ chat_mcp_tool_set: [ legacy ] })
      allow(Syrus::PluginRegistry).to receive(:all_plugins).and_return([ manifest ])
      allow(Syrus::Plugin::Toolkit).to receive(:chat_tool_set_for).with(manifest).and_return([ legacy ])
      expect(described_class.installed_chat_tool_sets).to eq([ legacy ])
    end

    it "does not let one provider's exception authorize another provider's omission" do
      excepted = Class.new do
        def self.tool_definitions(tier:) = [ { name: "shared_name" } ]
        def self.coworker_exception = { reason_code: "requires_coding_checkout", explanation: "x", owner: "o", test_ref: "t", absent_from: %i[coworker] }
        def self.to_s = "ExceptedSet"
      end
      other = Class.new do
        def self.tool_definitions(tier:) = [ { name: "shared_name" } ]
        def self.to_s = "OtherSet"
      end
      allow(Mcp::CoworkerToolExposure).to receive(:plugin_provider?) { |provider| provider != excepted }
      allow(Mcp::CoworkerToolExposure).to receive(:plugin_definition?).and_return(false)
      report = described_class.plugin_report([ excepted, other ])
      expect(report.join("\n")).not_to include("ExceptedSet#shared_name: unexplained")
      expect(report).to include(a_string_matching(/OtherSet#shared_name: unexplained absence from coworker/))
    end

    it "lists coworker-only plugin exceptions with their own rationale in generated docs" do
      markdown = Syrus::SurfaceCatalogs.render_parity_exceptions
      expect(markdown).to include("Coworker workspace, reply, schedule and spawn tools", "Sanitized Syrus diagnostics")
    end

    it "rejects a bare coworker_excluded key even when false" do
      expect { Mcp::CoworkerToolExposure.plugin_definition?({ name: "x", coworker_excluded: false }) }
        .to raise_error(ArgumentError, /coworker_excluded/)
    end

    it "share every Browser, Kubernetes, and Admin MySQL tool with coworkers" do
      shared = providers.select do |provider|
        %w[SyrusBrowser::ChatToolSet K8sCluster::ChatToolSet AdminMysql::ChatToolSet].include?(provider.name)
      end
      expect(shared).not_to be_empty
      shared.each do |provider|
        expect(Mcp::CoworkerToolExposure.plugin_provider?(provider)).to be(true)
        Array(provider.tool_definitions(tier: nil)).each do |definition|
          expect(Mcp::CoworkerToolExposure.plugin_definition?(definition)).to be(true)
        end
      end
    end

    it "names every coworker-only provider with a reviewed exception" do
      candidates = [ Coworkers::ChatToolSet, SyrusDev::ChatToolSet ]
      only = candidates.select { |provider| Mcp::CoworkerToolExposure.coworker_only_exception(provider) }
      expect(only).to match_array(candidates)
      # Every other installed provider is shared with coworkers.
      (providers - candidates).each do |provider|
        expect(Mcp::CoworkerToolExposure.coworker_only_exception(provider)).to be_nil
      end
      only.each do |provider|
        exception = Mcp::CoworkerToolExposure.coworker_only_exception(provider)
        expect(Rails.root.join(exception.test_ref)).to exist
      end
    end
  end
end
