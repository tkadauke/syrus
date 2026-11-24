require "rails_helper"

# The coworkers plugin owns the coworker side of interactive chat tool parity:
# the coworker baseline, its comparison rules, exceptions, and reason codes.
# Core (Mcp::ChatToolParity) is generic and proves the mechanism separately.
RSpec.describe Coworkers::ChatParity do
  let(:admin) { Factories.user(admin: true) }
  let(:member) { Factories.user }

  def coworker_names(user)
    context = McpToolContext.new(surface: :chat, role: AgentRole::COWORKER_CHAT, user: user)
    McpToolRegistry.tools_for_context(context, surface: :coworker).map { |tool| McpToolRegistry.tool_name_for(tool) }
  end

  it "is contributed through the coworkers chat tool set as the coworker context" do
    expect(Coworkers::ChatToolSet.chat_parity_participant).to eq(described_class)
    expect(Mcp::ChatToolParity.participants).to include(described_class)
    expect(Mcp::ChatToolParity.contexts).to eq(%i[planner coding local coworker])
  end

  it "activates no coworker parity policy at runtime while the plugin is disabled" do
    allow(Coworkers).to receive(:enabled?).and_return(false)

    expect(Mcp::ChatToolParity.participants).to include(described_class)
    expect(Mcp::ChatToolParity.participants(enabled_only: true)).not_to include(described_class)
    expect(Mcp::ChatToolParity.extension_context?(:coworker)).to be_falsey
    expect(Mcp::Sidecar.filter_by_policy([ { name: "x" } ], :coworker)).to eq([ { name: "x" } ])
  end

  # The registry memoizes each surface for the process, so the coworker surface
  # must not depend on whether the plugin was enabled when it was first built:
  # built while disabled, it used to keep Local Mode and runtime tools on the
  # coworker surface for the rest of the process (and in the generated catalog).
  it "builds the same coworker surface whether or not the plugin is enabled when first built" do
    surface = lambda do
      McpToolRegistry.remove_instance_variable(:@entries) if McpToolRegistry.instance_variable_defined?(:@entries)
      McpToolRegistry.remove_instance_variable(:@entries_by_surface) if McpToolRegistry.instance_variable_defined?(:@entries_by_surface)
      McpToolRegistry.entries(surface: :coworker).map(&:tool_name).sort
    end
    cached_entries = McpToolRegistry.instance_variable_get(:@entries)
    cached_entries_by_surface = McpToolRegistry.instance_variable_get(:@entries_by_surface)

    enabled = surface.call
    allow(Coworkers).to receive(:enabled?).and_return(false)
    disabled = surface.call

    expect(disabled).to eq(enabled)
    expect(disabled).not_to include("create_coding_job", "run_command", "write_file")
  ensure
    McpToolRegistry.instance_variable_set(:@entries, cached_entries)
    McpToolRegistry.instance_variable_set(:@entries_by_surface, cached_entries_by_surface)
  end

  it "has no unexplained differences between planner, coding, local, and coworker catalogs" do
    expect(Mcp::ChatToolParity.report).to eq([])
  end

  it "fails on an unexplained omission or a stale exception" do
    stripped = Class.new do
      class << self
        delegate :context, :enabled?, :reason_codes, to: Coworkers::ChatParity
        def exceptions = Coworkers::ChatParity.exceptions.reject { |e| e[:reason_code] == "owner_permission_decision" }
      end
    end

    expect(Mcp::ChatToolParity.report(participants: [ stripped ]).join("\n"))
      .to match(/grant_permission: unexplained absence from coworker/)

    stale = Class.new do
      class << self
        delegate :context, :enabled?, :reason_codes, to: Coworkers::ChatParity
        def exceptions = Coworkers::ChatParity.exceptions + [ { reason_code: "owner_permission_decision", explanation: "x", owner: "o",
                                                                test_ref: Coworkers::ChatParity::SPEC, absent_from: %i[coworker], tools: [ "list_jobs" ] } ]
      end
    end
    expect(Mcp::ChatToolParity.report(participants: [ stale ]).join("\n")).to match(/list_jobs: exception no longer applies to coworker/)
  end

  it "requires reason, explanation, owner, and an existing test on every coworker exception" do
    exceptions = described_class.exceptions.map { |attributes| Mcp::ChatToolParity::ReviewedException.coerce(attributes) }
    expect(exceptions.map(&:reason_code).uniq).to match_array(
      %w[owner_permission_decision workflow_run_bound_verdict coworker_sanitized_surface coworker_identity_lifecycle]
    )
    exceptions.each do |exception|
      expect(described_class.reason_codes.merge(Mcp::ChatToolParity::CORE_REASON_CODES)).to include(exception.reason_code)
      expect([ exception.explanation, exception.owner, exception.test_ref ]).to all(be_present)
      expect(Rails.root.join(exception.test_ref)).to exist
    end
  end

  describe "admin tools" do
    it "are discoverable for admin-owned coworkers and absent for non-admin owners" do
      expect(coworker_names(admin)).to include("admin_overview", "force_fail_job", "read_worker_health")
      expect(coworker_names(member)).not_to include("admin_overview", "force_fail_job")
    end
  end

  describe "owner-side, lifecycle and run-bound exceptions" do
    it "stay unavailable to coworkers" do
      names = coworker_names(admin)

      expect(names).not_to include(*described_class::PERMISSION_TOOLS, *Mcp::ChatToolParity::WORKFLOW_VERDICT_TOOLS,
                                   *described_class::VERDICT_TOOLS)
    end

    it "keeps coworker-only reads and lifecycle requests out of the core contexts" do
      catalogs = Mcp::ChatToolParity.catalogs
      described_class::CORE_CONTEXTS.each do |context|
        expect(catalogs.fetch(context)).not_to include(*described_class::SANITIZED_TOOLS, *described_class::LIFECYCLE_TOOLS)
      end
      expect(catalogs.fetch(:coworker)).to include(*described_class::SANITIZED_TOOLS, *described_class::LIFECYCLE_TOOLS)
    end

    it "hide checkout-bound tools from coworkers" do
      expect(coworker_names(admin)).not_to include("run_command", "runtime_start", "submit_coding_changes", "write_file")
    end
  end

  describe "plugin tool sets" do
    it "share Browser, Kubernetes and Admin MySQL tools with coworkers without exception" do
      shared = Mcp::ChatToolParity.installed_chat_tool_sets.select do |provider|
        %w[SyrusBrowser::ChatToolSet K8sCluster::ChatToolSet AdminMysql::ChatToolSet].include?(provider.name)
      end
      expect(shared).not_to be_empty
      shared.each do |provider|
        expect(Mcp::ChatToolParity.provider_exceptions(provider)).to be_empty
        expect(Mcp::ChatToolParity.plugin_provider_in_context?(provider, :coworker)).to be(true)
      end
    end

    it "names the coworker-only providers with a reviewed exception absent from every core context" do
      only = Mcp::ChatToolParity.installed_chat_tool_sets.select { |provider| described_class.coworker_only?(provider) }
      expect(only).to match_array([ Coworkers::ChatToolSet, SyrusDev::ChatToolSet ])
    end

    it "uses ordinary availability for shared providers and coworker availability for coworker-only ones" do
      chat = instance_double(ChatSession)
      shared = class_double("SharedToolSet", available_for?: true, tool_definitions: [], available_for_coworker?: false)
      allow(Mcp::ChatToolParity).to receive(:provider_exceptions).and_call_original
      allow(Mcp::ChatToolParity).to receive(:provider_exceptions).with(shared).and_return([])
      expect(described_class.provider_available?(shared, chat, tier: :essential)).to be(true)

      expect(described_class.provider_available?(Coworkers::ChatToolSet, chat, tier: :essential)).to eq(
        Coworkers::ChatToolSet.available_for_coworker?(chat, tier: :essential)
      )
    end

    it "rejects the removed boolean exclusion APIs and incomplete exception metadata" do
      expect { described_class.validate_definition!({ name: "x", coworker_excluded: false }) }
        .to raise_error(ArgumentError, /coworker_excluded/)
      expect { Mcp::ChatToolParity.plugin_definition_in_context?({ name: "x", coworker_excluded: true }, :coworker) }
        .to raise_error(ArgumentError, /removed `coworker_excluded`/)
      expect { described_class.validate_provider!(class_double("Bool", coworker_excluded?: true)) }
        .to raise_error(ArgumentError, /removed boolean/)
      expect { described_class.validate_provider!(class_double("Bool", coworker_specific_availability?: true)) }
        .to raise_error(ArgumentError, /removed boolean/)
      expect { Mcp::ChatToolParity.definition_exception({ name: "x", parity_exception: { reason_code: "requires_coding_checkout" } }) }
        .to raise_error(ArgumentError, /missing explanation, owner, test_ref/)
    end

    it "lists coworker exceptions with their own rationale in generated docs" do
      markdown = Syrus::SurfaceCatalogs.render_parity_exceptions

      expect(markdown).to include("Coworker workspace, reply, schedule and spawn tools", "must not grant, deny, lease, or revoke its own permissions")
    end
  end
end
