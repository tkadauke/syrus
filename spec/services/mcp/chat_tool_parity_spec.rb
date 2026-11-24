require "rails_helper"

# Generic interactive chat tool parity infrastructure. Context-specific policy
# (for example a plugin's own chat context) is owned and tested by the plugin
# that contributes it; this spec proves the mechanism with no participant and
# with a synthetic one.
RSpec.describe Mcp::ChatToolParity do
  let(:admin) { Factories.user(admin: true) }

  def exception_attributes(overrides = {})
    { reason_code: "requires_coding_checkout", explanation: "Needs a checkout.", owner: "example",
      test_ref: "spec/services/mcp/chat_tool_parity_spec.rb" }.merge(overrides)
  end

  def participant(context: :probe, tools: [], **extra)
    Class.new do
      define_singleton_method(:context) { context }
      define_singleton_method(:enabled?) { true }
      define_singleton_method(:reason_codes) { {} }
      define_singleton_method(:exceptions) { tools }
      extra.each { |name, impl| define_singleton_method(name, &impl) }
    end
  end

  it "names no plugin-owned chat context in core and has no context-specific policy without participants" do
    source = File.read(Rails.root.join("app/services/mcp/chat_tool_parity.rb"))

    expect(source).not_to match(/coworker/i)
    expect(defined?(Mcp::CoworkerToolExposure)).to be_nil
    expect(described_class.contexts(participants: [])).to eq(described_class::CORE_CONTEXTS)
    expect(described_class.core_exceptions(participants: [])).to eq(described_class::CORE_EXCEPTIONS)
    expect(described_class.reason_codes(participants: [])).to eq(described_class::CORE_REASON_CODES)
  end

  it "has no unexplained differences between the core chat contexts" do
    expect(described_class.report(participants: [], providers: [])).to eq([])
  end

  it "requires reason, explanation, owner, and test on every core exception" do
    expect(described_class.exceptions(participants: [])).not_to be_empty
    described_class.exceptions(participants: []).each do |exception|
      expect(described_class::CORE_REASON_CODES).to include(exception.reason_code)
      expect([ exception.explanation, exception.owner, exception.test_ref ]).to all(be_present)
      expect(Rails.root.join(exception.test_ref)).to exist
    end
    expect(described_class::CORE_REASON_CODES.keys).to match_array(
      %w[workflow_run_bound_verdict evaluator_run_bound requires_coding_checkout requires_local_checkout]
    )
  end

  it "refuses incomplete or malformed exception declarations" do
    expect { described_class::ReviewedException.build(**exception_attributes(explanation: " ")) }
      .to raise_error(ArgumentError, /missing explanation/)
    expect { described_class::ReviewedException.build(**exception_attributes(owner: nil, test_ref: "")) }
      .to raise_error(ArgumentError, /missing owner, test_ref/)
    expect { described_class::ReviewedException.build(**exception_attributes(reason_code: "Because I Said")) }
      .to raise_error(ArgumentError, /snake_case/)
  end

  it "reports a stale core exception whose tool is no longer absent" do
    stale = participant(tools: [ exception_attributes(absent_from: %i[probe], tools: [ "list_jobs" ]) ])
    allow(McpToolRegistry).to receive(:entries).and_call_original
    allow(McpToolRegistry).to receive(:entries).with(surface: :probe).and_return(McpToolRegistry.entries(surface: :chat))

    expect(described_class.report(participants: [ stale ], providers: []).join("\n")).to match(/list_jobs: exception no longer applies to probe/)
  end

  it "reports an unexplained omission from a participant context and unknown reason codes" do
    probe = participant(tools: [ exception_attributes(reason_code: "made_up", absent_from: %i[probe], tools: [ "list_jobs" ]) ])
    entries = McpToolRegistry.entries(surface: :chat).reject { |entry| %w[list_jobs read_job].include?(entry.tool_name) }
    allow(McpToolRegistry).to receive(:entries).and_call_original
    allow(McpToolRegistry).to receive(:entries).with(surface: :probe).and_return(entries)

    report = described_class.report(participants: [ probe ], providers: []).join("\n")
    expect(report).to match(/read_job: unexplained absence from probe/)
    expect(report).to match(/unknown reason code made_up/)
    expect(report).not_to match(/list_jobs: unexplained/)
  end

  describe "core entries and role gates" do
    it "derives absences for role-gated tools from the role requirement" do
      coding = McpToolRegistry.entries(surface: :chat).find { |entry| entry.required_roles.include?(AgentRole::CHAT_CODING) }
      probe = participant

      expect(described_class.core_entry_in_context?(coding, :planner, participants: [ probe ])).to be(false)
      expect(described_class.core_entry_in_context?(coding, :coding, participants: [ probe ])).to be(true)
      expect(described_class.core_entry_in_context?(coding, :probe, participants: [ probe ])).to be(false)
    end

    it "hides workflow verdict tools from every context" do
      absences = described_class.declared_absences("submit_summary", nil, participants: [ participant ])
      expect(absences).to match_array(%i[planner coding local probe])
    end
  end

  describe "plugin chat tool sets" do
    let(:providers) { described_class.installed_chat_tool_sets }

    it "have no unexplained differences across installed contexts" do
      expect(described_class.plugin_report(providers)).to eq([])
      expect(described_class.plugin_catalogs(providers).keys).to match_array(providers)
    end

    it "names every plugin exception with a reason code its owner declared and an existing test" do
      described_class.plugin_exceptions_by_provider(providers).each do |provider, exceptions|
        own = provider.respond_to?(:chat_parity_reason_codes) ? provider.chat_parity_reason_codes : {}
        codes = described_class.reason_codes.merge(own)
        exceptions.each do |exception|
          expect(codes).to include(exception.reason_code)
          expect([ exception.explanation, exception.owner ]).to all(be_present)
          expect(Rails.root.join(exception.test_ref)).to exist
        end
      end
    end

    it "fails on an undeclared plugin omission and accepts a declared one" do
      declared = Class.new do
        def self.tool_definitions(tier:) = [ { name: "plugin_probe" } ]
        def self.chat_parity_exceptions
          [ { reason_code: "requires_coding_checkout", explanation: "x", owner: "o", test_ref: "t", absent_from: %i[local] } ]
        end
        def self.to_s = "DeclaredSet"
      end
      silent = Class.new do
        def self.tool_definitions(tier:) = [ { name: "plugin_probe", parity_exception: nil } ]
        def self.to_s = "SilentSet"
      end
      expect(described_class.plugin_report([ declared ], participants: [])).to eq([])

      hidden = Class.new do
        def self.tool_definitions(tier:) = [ { name: "plugin_probe", parity_exception: { reason_code: "requires_coding_checkout", explanation: "x", owner: "o", test_ref: "t", absent_from: %i[local] } } ]
        def self.to_s = "HiddenSet"
      end
      expect(described_class.plugin_report([ hidden ], participants: [])).to eq([])
      expect(described_class.plugin_catalogs([ silent ], participants: []).values.first.values).to all(include("plugin_probe"))
    end

    it "flags undeclared reason codes and unknown contexts" do
      bad = Class.new do
        def self.tool_definitions(tier:) = [ { name: "plugin_probe" } ]
        def self.chat_parity_exceptions
          [ { reason_code: "because", explanation: "x", owner: "o", test_ref: "t", absent_from: %i[nowhere] } ]
        end
        def self.to_s = "BadSet"
      end

      report = described_class.plugin_report([ bad ], participants: []).join("\n")
      expect(report).to match(/undeclared reason code because/)
      expect(report).to match(/unknown context nowhere/)
    end

    it "does not let one provider's exception authorize another provider's omission" do
      excepted = Class.new do
        def self.tool_definitions(tier:) = [ { name: "shared_name" } ]
        def self.chat_parity_exceptions
          [ { reason_code: "requires_coding_checkout", explanation: "x", owner: "o", test_ref: "t", absent_from: %i[local] } ]
        end
        def self.to_s = "ExceptedSet"
      end
      other = Class.new do
        def self.tool_definitions(tier:) = [ { name: "shared_name" } ]
        def self.to_s = "OtherSet"
      end

      by_provider = described_class.plugin_exceptions_by_provider([ excepted, other ])
      expect(by_provider.fetch(excepted)).not_to be_empty
      expect(by_provider.fetch(other)).to be_empty
      expect(described_class.plugin_catalogs([ excepted, other ], participants: []).fetch(other).fetch(:local)).to include("shared_name")
      expect(described_class.plugin_catalogs([ excepted, other ], participants: []).fetch(excepted).fetch(:local)).to be_empty
    end

    it "applies admin gating to admin-only definitions in every context" do
      definition = { name: "admin_thing", admin_only: true }

      expect(described_class.plugin_definition_in_context?(definition, :planner, participants: [])).to be(false)
      expect(described_class.plugin_definition_in_context?(definition, :planner, user: double(admin?: false), participants: [])).to be(false)
      expect(described_class.plugin_definition_in_context?(definition, :planner, user: admin, participants: [])).to be(true)
    end

    it "lists every accepted exception with its rationale in generated docs" do
      markdown = Syrus::SurfaceCatalogs.render_parity_exceptions

      described_class.exceptions.each { |exception| expect(markdown).to include(exception.explanation) }
      expect(markdown).to include("Sanitized Syrus diagnostics")
    end
  end
end
