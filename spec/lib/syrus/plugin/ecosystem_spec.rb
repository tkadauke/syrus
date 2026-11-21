require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe Syrus::Plugin::Ecosystem, :reset_plugin_registry do
  let(:definition) { Syrus::Plugin::Family.fetch(:ecosystem) }

  it "defines all ecosystem contracts, tiers, contexts, and legacy mappings" do
    expect(definition.capabilities.transform_values { |capability|
      [ capability.composition, capability.absent, capability.tier, capability.context ]
    }).to eq(
      detect_prepare: [ :collect, [], :stable, Syrus::Plugin::Context::RepoContext ],
      grade_candidates: [ :collect, [], :stable, Syrus::Plugin::Context::RepoContext ],
      grader_types: [ :keyed, :configuration_error, :stable, Syrus::Plugin::Context::GraderContext ],
      grader_diagnostics: [ :broadcast, nil, :stable, Syrus::Plugin::Context::GraderContext ],
      review_criteria: [ :collect, [], :stable, Syrus::Plugin::Context::RepoContext ],
      prompt_context: [ :collect, [], :stable, Syrus::Plugin::Context::JobContext ],
      autofix: [ :collect, [], :stable, Syrus::Plugin::Context::WorkspaceContext ],
      dependency_audit: [ :collect, [], :stable, Syrus::Plugin::Context::WorkspaceContext ],
      focused_tests: [ :first_claim, nil, :stable, Syrus::Plugin::Context::GraderContext ],
      analyze_coverage: [ :first_claim, nil, :stable, Syrus::Plugin::Context::WorkspaceContext ],
      affected_tests: [ :collect, [], :provisional, Syrus::Plugin::Context::WorkspaceContext ],
      parse_ci_log: [ :first_claim, nil, :provisional, Syrus::Plugin::Context::GraderContext ],
      review_file_patterns: [ :collect, [], :provisional, Syrus::Plugin::Context::RepoContext ],
      target_graph: [ :keyed, :configuration_error, :provisional, Syrus::Plugin::Context::RepoContext ]
    )
    expect(definition.legacy_mappings.keys).to match_array(%i[
      prepare_detector grade_detector grader_type grader_augmentor review_criteria_provider
      autofix_command dependency_audit_command focused_test_command coverage_analyzer
      affected_test_analyzer ci_log_parser prompt_injector diff_review_file_pattern_provider
      build_system_graph_provider
    ])
  end

  it "dispatches every capability with its declared composition and decline behavior" do
    calls = []
    provider = Class.new do
      define_singleton_method(:detect_prepare) { |_context| [ Syrus::Plugin::Ecosystem::PreparePlan.new(detected: true, commands: [ "prepare" ]) ] }
      define_singleton_method(:grade_candidates) { |_context| [ { name: "test" } ] }
      define_singleton_method(:grader_types) { |_context| [ :step ] }
      define_singleton_method(:grader_diagnostics) { |_context| calls << :diagnostic; nil }
      define_singleton_method(:review_criteria) { |_context| [ "review" ] }
      define_singleton_method(:prompt_context) { |_context| "prompt" }
      define_singleton_method(:autofix) { |_context| "format" }
      define_singleton_method(:dependency_audit) { |_context| Syrus::Plugin::Ecosystem::DependencyAuditPlan.new(lockfiles: [ "lock" ], command: "audit") }
      define_singleton_method(:focused_tests) { |_context| "focused" }
      define_singleton_method(:analyze_coverage) { |_context| :coverage }
      define_singleton_method(:affected_tests) { |_context| [ "spec/a_spec.rb" ] }
      define_singleton_method(:parse_ci_log) { |_context| { parser: :fake, error_summary: "bad", error_block: "details" } }
      define_singleton_method(:review_file_patterns) { |_context| [ "generated/**", { glob: "vendor/**" } ] }
      define_singleton_method(:target_graph) { |_context| :graph }
    end
    stub_const("EcosystemDispatchFixture", provider)
    references = definition.capabilities.to_h do |name, capability|
      key = %i[grader_types target_graph].include?(name) ? :fixture : nil
      reference = Syrus::Plugin::CapabilityProvider.new(plugin_name: "fixture", family: :ecosystem,
        capability: name, provider_name: provider.name, key:, priority: 0)
      [ name, [ reference ] ]
    end
    allow(Syrus::PluginRegistry).to receive(:capability_providers) { |_family, capability| references.fetch(capability) }

    contexts = {
      detect_prepare: repo_context, grade_candidates: repo_context, grader_types: grader_context,
      grader_diagnostics: grader_context, review_criteria: repo_context, prompt_context: job_context,
      autofix: workspace_context, dependency_audit: workspace_context, focused_tests: grader_context,
      analyze_coverage: workspace_context, affected_tests: workspace_context, parse_ci_log: grader_context,
      review_file_patterns: repo_context, target_graph: repo_context
    }
    results = contexts.to_h do |capability, context|
      key = %i[grader_types target_graph].include?(capability) ? :fixture : nil
      [ capability, Syrus::Plugin::Dispatch.call(:ecosystem, capability, context, key:) ]
    end

    expect(results).to include(prompt_context: [ "prompt" ], autofix: [ "format" ], focused_tests: "focused",
      analyze_coverage: :coverage, affected_tests: [ "spec/a_spec.rb" ], target_graph: :graph)
    expect(results[:detect_prepare].sole).to be_detected
    expect(results[:dependency_audit].sole.command).to eq("audit")
    expect(results[:review_file_patterns]).to eq([ "generated/**", { glob: "vendor/**" } ])
    expect(calls).to eq([ :diagnostic ])
  end

  it "answers a legacy prepare lookup from a family provider with the merged plan" do
    provider = Class.new do
      def self.key = :fixture
      def self.display_name = "Fixture"
      def self.detect_prepare(context)
        [ Syrus::Plugin::Ecosystem::PreparePlan.new(detected: context.repo_path == "/repo",
          commands: [ "bundle install" ], version_file: ".ruby-version", span_labels: [ [ /rspec/, "rspec" ] ]) ]
      end
    end
    stub_const("EcosystemLegacyFixture", provider)
    declaration = Syrus::Plugin::FamilyDeclaration.build(family: :ecosystem, provider: provider.name,
      implements: %i[detect_prepare])
    Syrus::PluginRegistry.register(name: "ecosystem_fixture", version: "1", family_provides: [ declaration ])

    legacy = Syrus::PluginRegistry.providers_for(:prepare_detector).find do |candidate|
      candidate.is_a?(Syrus::Plugin::LegacyBridge::Provider)
    end
    expect(legacy.detect?("/repo")).to be(true)
    expect(legacy.prepare_commands("/repo")).to eq([ "bundle install" ])
    expect(legacy.mise_version_file).to eq(".ruby-version")
    expect(legacy.span_labels).to eq([ [ /rspec/, "rspec" ] ])
  end

  it "passes autofix and focused-test fields through typed contexts without reflecting on provider signatures" do
    seen = []
    provider = Class.new do
      define_singleton_method(:autofix) do |context|
        seen << [ :autofix, context.workspace_path, context.changed_files ]
        "format"
      end
      define_singleton_method(:focused_tests) do |context|
        seen << [ :focused, context.name, context.command, context.failed_cases, context.base_retry, context.project_path ]
        "focused"
      end
    end
    stub_const("EcosystemContextFixture", provider)
    references = {
      autofix: Syrus::Plugin::CapabilityProvider.new(plugin_name: "fixture", family: :ecosystem,
        capability: :autofix, provider_name: provider.name, key: nil, priority: 0),
      focused_tests: Syrus::Plugin::CapabilityProvider.new(plugin_name: "fixture", family: :ecosystem,
        capability: :focused_tests, provider_name: provider.name, key: nil, priority: 0)
    }
    allow(Syrus::PluginRegistry).to receive(:capability_providers) { |_family, capability| [ references.fetch(capability) ] }

    workspace = Syrus::Plugin::Context::WorkspaceContext.new(
      workspace_path: "/repo", changed_files: [ "app.rb" ]
    )
    grader = Syrus::Plugin::Context::GraderContext.new(
      name: "rspec", command: "bin/rspec", failed_cases: [ { "name" => "fails" } ],
      base_retry: { "strategy" => "provider" }, project_path: "backend", operation: :command
    )

    expect(Syrus::Plugin::Dispatch.call(:ecosystem, :autofix, workspace)).to eq([ "format" ])
    expect(Syrus::Plugin::Dispatch.call(:ecosystem, :focused_tests, grader)).to eq("focused")
    expect(seen).to eq([
      [ :autofix, "/repo", [ "app.rb" ] ],
      [ :focused, "rspec", "bin/rspec", [ { "name" => "fails" } ], { "strategy" => "provider" }, "backend" ]
    ])
  end

  it "provides conforming reference implementations for capabilities without bundled providers" do
    references = {
      parse_ci_log: Class.new { def self.parse_ci_log(context) = context.text == "failure" ? { parser: :fake, error_summary: "failure", error_block: "failure" } : nil },
      review_file_patterns: Class.new { def self.review_file_patterns(context) = context.repo_path ? [ "generated/**", { glob: "vendor/**" } ] : [] },
      target_graph: Class.new { def self.target_graph(context) = context.config ? { projects: [], targets: [] } : nil }
    }
    references.each_value do |provider|
      provider.define_singleton_method(:key) { :reference }
      provider.define_singleton_method(:display_name) { "Reference" }
    end
    contexts = {
      parse_ci_log: grader_context(text: "failure"),
      review_file_patterns: repo_context,
      target_graph: repo_context(config: {})
    }
    declines = {
      parse_ci_log: grader_context,
      review_file_patterns: Syrus::Plugin::Context::RepoContext.new(repo_path: nil),
      target_graph: repo_context
    }

    references.each do |capability, provider|
      tier = definition.capabilities.fetch(capability).tier
      declaration = Syrus::Plugin::FamilyDeclaration.build(family: :ecosystem, provider: "Reference",
        key: (capability == :target_graph ? :reference : nil),
        provisional: (tier == :provisional ? [ capability ] : []), implements: (tier == :stable ? [ capability ] : []))
      expect do
        Syrus::Plugin::FamilyContractKit.validate!(declaration:, provider:,
          contexts: { capability => contexts.fetch(capability) }, decline_contexts: { capability => declines.fetch(capability) })
      end.not_to raise_error
    end
  end

  it "rejects malformed CI-log and review-pattern results in the generated kit" do
    malformed = {
      parse_ci_log: Class.new { def self.parse_ci_log(_context) = { parser: :fake } },
      review_file_patterns: Class.new { def self.review_file_patterns(_context) = [ 123 ] }
    }
    malformed.each_value do |provider|
      provider.define_singleton_method(:key) { :malformed }
      provider.define_singleton_method(:display_name) { "Malformed" }
    end

    malformed.each do |capability, provider|
      declaration = Syrus::Plugin::FamilyDeclaration.build(family: :ecosystem, provider: "Malformed",
        provisional: [ capability ])
      expect do
        Syrus::Plugin::FamilyContractKit.validate!(declaration:, provider:,
          contexts: { capability => (capability == :parse_ci_log ? grader_context : repo_context) },
          decline_contexts: { capability => (capability == :parse_ci_log ? grader_context : Syrus::Plugin::Context::RepoContext.new(repo_path: nil)) })
      end.to raise_error(RSpec::Expectations::ExpectationNotMetError, /must return/)
    end
  end

  it "declines a malformed CI-log result and accepts the next valid claim through dispatch" do
    health = Syrus::PluginRuntimeHealth.new
    Syrus::PluginInvocation.runtime_health = health
    malformed = Class.new { def self.parse_ci_log(_context) = { parser: :incomplete } }
    valid = Class.new do
      def self.parse_ci_log(_context) = { parser: :reference, error_summary: "failure", error_block: "details" }
    end
    stub_const("MalformedCiLogFixture", malformed)
    stub_const("ValidCiLogFixture", valid)
    providers = [ malformed, valid ].map.with_index do |provider, priority|
      Syrus::Plugin::CapabilityProvider.new(plugin_name: "ci_#{priority}", family: :ecosystem,
        capability: :parse_ci_log, provider_name: provider.name, key: nil, priority:)
    end
    allow(Syrus::PluginRegistry).to receive(:capability_providers).with(:ecosystem, :parse_ci_log).and_return(providers)

    expect(Syrus::Plugin::Dispatch.call(:ecosystem, :parse_ci_log, grader_context)).to include(parser: :reference)
    expect(health.failures).to be_empty
    expect(health.circuits).to be_empty
  end

  def repo_context(config: nil) = Syrus::Plugin::Context::RepoContext.new(repo_path: "/repo", config:)
  def workspace_context = Syrus::Plugin::Context::WorkspaceContext.new(workspace_path: "/repo")
  def grader_context(**attributes) = Syrus::Plugin::Context::GraderContext.new(**attributes)
  def job_context = Syrus::Plugin::Context::JobContext.new(repository: nil, job: nil)
end
