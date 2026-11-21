require "rails_helper"

RSpec.describe "ecosystem capability call-site parity", :reset_plugin_registry do
  def results_for(capability, legacy:, family:, key: nil)
    definition = Syrus::Plugin::Family.fetch(:ecosystem)
    mapping = definition.legacy_mappings.values.find { |candidate| candidate.capability == capability }
    Syrus::PluginRegistry.register(mapping.extension_point, legacy)
    legacy_reference = Syrus::PluginRegistry.capability_providers(:ecosystem, capability).last
    allow(Syrus::PluginRegistry).to receive(:capability_providers)
      .with(:ecosystem, capability).and_return([ legacy_reference ])
    legacy_result = yield

    Syrus::PluginRegistry.reset!
    allow(Syrus::PluginRegistry).to receive(:capability_providers).and_call_original
    family.define_singleton_method(:key) { key || :parity } unless family.respond_to?(:key)
    family.define_singleton_method(:display_name) { "Parity" } unless family.respond_to?(:display_name)
    constant = "EcosystemCallSiteParity#{capability.to_s.camelize}#{family.object_id.abs}"
    stub_const(constant, family)
    contract = definition.capabilities.fetch(capability)
    declaration = Syrus::Plugin::FamilyDeclaration.build(
      family: :ecosystem, provider: constant, key:,
      implements: contract.tier == :stable ? [ capability ] : [],
      provisional: contract.tier == :provisional ? [ capability ] : []
    )
    Syrus::PluginRegistry.register(
      name: "parity-family", version: "1", family_provides: [ declaration ]
    )
    family_reference = Syrus::PluginRegistry.capability_providers(:ecosystem, capability)
      .find { |reference| reference.respond_to?(:plugin_name) && reference.plugin_name == "parity-family" }
    allow(Syrus::PluginRegistry).to receive(:capability_providers)
      .with(:ecosystem, capability).and_return([ family_reference ])

    [ legacy_result, yield ]
  end

  it "keeps RepoGradeSignals results equal for legacy and family grade providers" do
    candidate = { name: "custom", run: "bin/custom", evidence: "custom.yml" }
    legacy = Class.new { define_singleton_method(:grade_candidates) { |_repo_path| [ candidate ] } }
    family = Class.new { define_singleton_method(:grade_candidates) { |_context| [ candidate ] } }

    results = results_for(:grade_candidates, legacy:, family:) do
      RepoGradeSignals.new("/repo").send(:plugin_candidates).map { |entry| [ entry.name, entry.run ] }
    end

    expect(results).to eq([ [ [ "custom", "bin/custom" ] ] ] * 2)
  end

  it "keeps adversarial-review criteria equal for legacy and family providers" do
    legacy = Class.new { define_singleton_method(:criteria) { |_repo_path| [ "Check queries" ] } }
    family = Class.new { define_singleton_method(:review_criteria) { |_context| [ "Check queries" ] } }
    handler = Steps::AdversarialReview.allocate
    allow(handler).to receive(:workspace).and_return(double(path: Pathname("/repo")))

    results = results_for(:review_criteria, legacy:, family:) do
      handler.send(:plugin_review_criteria)
    end

    expect(results).to eq([ [ "Check queries" ], [ "Check queries" ] ])
  end

  it "keeps format commands and workspace context equal for legacy and family providers" do
    seen = []
    legacy = Class.new do
      define_singleton_method(:autofix_command) do |workspace_path:, changed_files:|
        seen << [ workspace_path.to_s, changed_files ]
        "bin/format"
      end
    end
    family = Class.new do
      define_singleton_method(:autofix) do |context|
        seen << [ context.workspace_path.to_s, context.changed_files ]
        "bin/format"
      end
    end
    handler = Steps::Format.allocate
    allow(handler).to receive(:workspace).and_return(double(path: Pathname("/repo")))

    results = results_for(:autofix, legacy:, family:) do
      handler.send(:plugin_default_commands, %w[app/a.rb app/b.rb])
    end

    expect(results).to eq([ [ "bin/format" ], [ "bin/format" ] ])
    expect(seen).to eq([ [ "/repo", %w[app/a.rb app/b.rb] ] ] * 2)
  end

  it "keeps grader-fanout affected files equal for legacy and family analyzers" do
    seen = []
    legacy = Class.new do
      define_singleton_method(:affected_files) do |repo_path:, changed_files:|
        seen << [ repo_path, changed_files ]
        [ "spec/generated_spec.rb" ]
      end
    end
    family = Class.new do
      define_singleton_method(:affected_tests) do |context|
        seen << [ context.workspace_path, context.changed_files ]
        [ "spec/generated_spec.rb" ]
      end
    end
    handler = Steps::GraderFanout.allocate
    allow(handler).to receive(:workspace).and_return(double(path: Pathname("/repo")))

    results = results_for(:affected_tests, legacy:, family:) do
      handler.send(:affected_test_files, [ "app/model.rb" ])
    end

    expect(results).to eq([ [ "spec/generated_spec.rb" ] ] * 2)
    expect(seen).to eq([ [ "/repo", [ "app/model.rb" ] ] ] * 2)
  end

  it "keeps BaseRevisionRetry focused commands equal for legacy and family providers" do
    legacy = Class.new do
      def self.command_for(**) = "bin/rspec spec/widget_spec.rb"
    end
    family = Class.new do
      def self.focused_tests(context)
        "bin/rspec #{context.failed_cases.first.fetch("file_path")}"
      end
    end
    step = double(details: { "name" => "rspec", "command" => "bin/rspec", "project_path" => "backend" })
    retry_check = BaseRevisionRetry.new(
      workflow: nil, grader_step: step, base_sha: "base",
      failed_cases: [ { "file_path" => "spec/widget_spec.rb" } ], log: ->(_message) { }
    )

    results = results_for(:focused_tests, legacy:, family:) do
      retry_check.send(:focused_command, { "strategy" => "provider" })
    end

    expect(results).to eq([ "bin/rspec spec/widget_spec.rb" ] * 2)
  end

  it "keeps isolated repro commands equal for legacy and family providers" do
    test_case = { "suite_name" => "spec/widget_spec.rb", "name" => "fails" }
    legacy = Class.new do
      def self.isolated_command_for(**) = "bin/rspec spec/widget_spec.rb"
    end
    family = Class.new do
      def self.focused_tests(context)
        "bin/rspec #{context.test_case.fetch("suite_name")}"
      end
    end
    recorder = IsolatedReproRecorder.new(
      run: double(workflow: nil, job: nil), grader_name: "rspec",
      suite_name: test_case["suite_name"], name: test_case["name"], reproduced: false
    )
    grader_step = double(details: { "command" => "bin/rspec" })

    results = results_for(:focused_tests, legacy:, family:) do
      recorder.send(:isolated_command_for, grader_step, test_case)
    end

    expect(results).to eq([ "bin/rspec spec/widget_spec.rb" ] * 2)
  end

  it "keeps merge-train focused commands equal for legacy and family providers" do
    failed_cases = [ { "file_path" => "spec/widget_spec.rb" } ]
    legacy = Class.new do
      def self.command_for(**) = "bin/rspec spec/widget_spec.rb"
    end
    family = Class.new do
      def self.focused_tests(context)
        "bin/rspec #{context.failed_cases.first.fetch("file_path")}"
      end
    end
    evaluator = MergeTrainMultisect::FocusedEvaluator.new(
      workflow: double, train: double, workspace_path: "/repo"
    )
    step = double(details: {
      "command" => "bin/rspec", "project_path" => "backend",
      "base_retry" => { "strategy" => "provider" }
    })
    context = MergeTrainMultisect::FocusedEvaluator::GraderContext.new(step, "rspec", failed_cases)

    results = results_for(:focused_tests, legacy:, family:) do
      evaluator.send(:focused_command, context)
    end

    expect(results).to eq([ "bin/rspec spec/widget_spec.rb" ] * 2)
  end

  it "keeps every prepare-plan consumer equal for legacy and family providers" do
    legacy = Class.new do
      def self.detect?(_repo_path) = true
      def self.prepare_commands(_repo_path) = [ "bin/install" ]
      def self.mise_version_file = "tool-version"
      def self.span_labels = [ [ /rspec/, "test" ] ]
      def self.name = "Legacy prepare"
    end
    family = Class.new do
      def self.detect_prepare(_context)
        [ Syrus::Plugin::Ecosystem::PreparePlan.new(
          detected: true, commands: [ "bin/install" ], version_file: "tool-version",
          span_labels: [ [ /rspec/, "test" ] ], label: "Legacy prepare"
        ) ]
      end
    end
    Dir.mktmpdir("ecosystem-prepare-parity") do |dir|
      path = Pathname(dir)
      path.join("tool-version").write("1")
      results = results_for(:detect_prepare, legacy:, family:) do
        snapshot = AgentEnvironmentSnapshot.new(workspace_path: path)
        spans = GraderCommandSpans::Plan.allocate
        prep_plan = RepoPrepPlan.new(path)
        probe = RepositoryExecutionProbeRunner.allocate
        probe.instance_variable_set(:@path, path)
        prepare = Steps::Prepare.allocate
        allow(prepare).to receive(:workspace).and_return(double(path:))

        {
          snapshot: snapshot.send(:dependency_summary),
          spans: spans.send(:plugin_span_labels),
          repo_prep: prep_plan.send(:plugin_detector_matches),
          probe: probe.send(:version_declared?),
          prepare: prepare.send(:mise_version_file?)
        }
      end

      expect(results.first).to eq(results.second)
      expect(results.first).to include(
        snapshot: "Legacy prepare (bin/install)",
        repo_prep: [ [ "Legacy prepare", [ "bin/install" ] ] ],
        probe: true,
        prepare: true
      )
      expect(results.first[:spans].first.last).to eq("test")
    end
  end

  it "keeps Steps::Base prompt context equal for legacy and family providers" do
    repository = double("repository")
    job = double("job", repository:)
    legacy = Class.new do
      define_singleton_method(:call) { |repository:, job:| "#{repository}:#{job}" }
    end
    family = Class.new do
      define_singleton_method(:prompt_context) { |context| "#{context.repository}:#{context.job}" }
    end
    handler = Steps::Base.allocate
    allow(handler).to receive(:repository).and_return(repository)
    allow(handler).to receive(:job).and_return(job)

    results = results_for(:prompt_context, legacy:, family:) do
      handler.send(:collect_injected_context)
    end

    expect(results.first).to eq(results.second)
    expect(results.first.sole).to include("repository", "job")
  end

  it "keeps coverage analysis equal for legacy and family providers" do
    artifact = Pathname("/repo/coverage.json")
    legacy = Class.new do
      def self.call(artifact_path:, format_hint:) = { path: artifact_path.to_s, format: format_hint }
    end
    family = Class.new do
      def self.analyze_coverage(context) = { path: context.artifact_path.to_s, format: context.format_hint }
    end
    handler = Steps::CoverageAnalyze.allocate

    results = results_for(:analyze_coverage, legacy:, family:) do
      handler.send(:try_plugin_parsers, artifact, "simplecov")
    end

    expect(results).to eq([ { path: artifact.to_s, format: "simplecov" } ] * 2)
  end

  it "keeps dependency-audit plan selection equal for legacy and family providers" do
    legacy = Class.new do
      def self.lockfiles = [ "Gemfile.lock" ]
      def self.audit_command(workspace_path:) = "cd #{workspace_path} && bin/audit"
    end
    family = Class.new do
      def self.dependency_audit(context)
        Syrus::Plugin::Ecosystem::DependencyAuditPlan.new(
          lockfiles: [ "Gemfile.lock" ], command: "cd #{context.workspace_path} && bin/audit", label: "Parity"
        )
      end
    end
    handler = Steps::DependencyAudit.allocate
    allow(handler).to receive(:workspace).and_return(double(path: Pathname("/repo")))

    results = results_for(:dependency_audit, legacy:, family:) do
      handler.send(:matching_plans, [ "Gemfile.lock" ]).map { |plan| [ plan.lockfiles, plan.command ] }
    end

    expect(results).to eq([ [ [ [ "Gemfile.lock" ], "cd /repo && bin/audit" ] ] ] * 2)
  end

  it "keeps CI-log parsing equal for legacy and family providers" do
    parsed = { parser: :parity, error_summary: "failed", error_block: "details" }
    legacy = Class.new { define_singleton_method(:call) { |text:, step_name:| parsed.merge(seen: [ text, step_name ]) } }
    family = Class.new do
      define_singleton_method(:parse_ci_log) { |context| parsed.merge(seen: [ context.text, context.step_name ]) }
    end
    parser = CiLogParser.new("failure output", step_name: "tests")

    results = results_for(:parse_ci_log, legacy:, family:) do
      parser.send(:try_plugin_parsers, "failure output")
    end

    expect(results.first).to eq(results.second)
    expect(results.first).to include(parser: :parity, seen: [ "failure output", "tests" ])
  end

  it "keeps keyed grader-type expansion equal for legacy and family providers" do
    legacy = Class.new do
      def self.type_name = :parity
      def self.grade_steps(config:, default_failures:) = [ config.merge("failures" => default_failures) ]
    end
    family = Class.new do
      def self.grader_types(context) = [ context.config.merge("failures" => context.default_failures) ]
    end
    config = SyrusYml.allocate
    config.instance_variable_set(:@project_path, "backend")

    results = results_for(:grader_types, legacy:, family:, key: :parity) do
      config.send(:expand_plugin_grade_type, "parity", { "name" => "custom" }, "grade[0]", default_failures: "warn")
    end

    expect(results.first).to eq(results.second)
    expect(results.first.sole).to include("name" => "custom", "failures" => "warn", "_syrus_project_path" => "backend")
  end

  it "keeps unlanding affected-test expansion equal for legacy and family providers" do
    legacy = Class.new do
      def self.affected_files(repo_path:, changed_files:) = changed_files.map { |file| "#{repo_path}/#{file}.spec" }
    end
    family = Class.new do
      def self.affected_tests(context) = context.changed_files.map { |file| "#{context.workspace_path}/#{file}.spec" }
    end
    creator = Unlanding::Create.allocate

    results = results_for(:affected_tests, legacy:, family:) do
      creator.send(:affected_test_files, Pathname("repo"), [ "app.rb" ])
    end

    expect(results).to eq([ [ "app.rb", "repo/app.rb.spec" ] ] * 2)
  end

  it "keeps diff-review pattern classification equal for legacy and family providers" do
    pattern = { glob: "generated/**", reason: "generated", source: "parity" }
    legacy = Class.new { define_singleton_method(:diff_review_file_patterns) { [ pattern ] } }
    family = Class.new { define_singleton_method(:review_file_patterns) { |_context| [ pattern ] } }
    classifier = App::DiffReviewFileClassifier.new(repository: nil, user: nil)

    results = results_for(:review_file_patterns, legacy:, family:) do
      classifier.send(:diff_review_file_pattern_provider_patterns).map(&:to_h)
    end

    expect(results.first).to eq(results.second)
    expect(results.first.sole).to include(glob: "generated/**", source: "parity")
  end

  it "keeps diff-review lockfile classification equal for legacy and family providers" do
    legacy = Class.new do
      def self.lockfiles = [ "custom.lock" ]
    end
    family = Class.new do
      def self.dependency_audit(_context)
        Syrus::Plugin::Ecosystem::DependencyAuditPlan.new(lockfiles: [ "custom.lock" ])
      end
    end
    classifier = App::DiffReviewFileClassifier.new(repository: nil, user: nil)

    results = results_for(:dependency_audit, legacy:, family:) do
      classifier.send(:plugin_lockfile_patterns).map(&:to_h)
    end

    expect(results.first).to eq(results.second)
    expect(results.first.sole).to include(glob: "custom.lock", reason: "lockfile")
  end

  it "keeps target-graph imports equal for legacy and family providers" do
    imported = TargetGraph::Import.new(projects: [], targets: [])
    legacy = Class.new do
      define_singleton_method(:provider_key) { :parity }
      define_singleton_method(:import_target_graph) { |repo_path:, config:| imported if repo_path && config == { "mode" => "test" } }
    end
    family = Class.new do
      define_singleton_method(:target_graph) { |context| imported if context.repo_path && context.config == { "mode" => "test" } }
    end
    Dir.mktmpdir("ecosystem-target-graph-parity") do |dir|
      File.write(File.join(dir, ".syrus.yml"), <<~YAML)
        target_graph:
          imports:
            - provider: parity
              config:
                mode: test
      YAML

      results = results_for(:target_graph, legacy:, family:, key: :parity) do
        graph = TargetGraph::Compiler.compile(dir)
        [ graph.projects.keys, graph.targets.keys ]
      end

      expect(results.first).to eq(results.second)
      expect(results.first.last).to include("//:repo")
    end
  end
end
