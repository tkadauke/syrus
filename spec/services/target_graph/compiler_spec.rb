require "rails_helper"
require "tmpdir"

RSpec.describe TargetGraph::Compiler do
  around do |ex|
    Dir.mktmpdir("syrus-target-graph-compiler") { |dir| @dir = dir; ex.run }
  end

  describe ".compile" do
    it "returns just the implicit root project/target when no .syrus.yml is present" do
      graph = described_class.compile(@dir)

      expect(graph.targets.keys).to eq(%w[//:repo])
      expect(graph.projects.keys).to eq(%w[repo])
      expect(graph.validate!).to be(true)
    end

    it "compiles grade steps into required grader targets depending on the root, preserving phases/required/timeout" do
      write(".syrus.yml", <<~YAML)
        grade:
          - name: tests
            run: bin/rspec
            phases: [review, landing]
            timeout_minutes: 30
          - name: audit
            run: bin/bundler-audit
            required: false
            when_files_changed: ["Gemfile.lock"]
            junit_output: tmp/audit.xml
            description: Checks for known CVEs.
      YAML

      graph = described_class.compile(@dir)

      tests = graph.target(TargetGraph::Label.parse("//:grade/tests"))
      expect(tests.kind).to eq("grader")
      expect(tests.project_id).to eq("repo")
      expect(tests.command).to eq("bin/rspec")
      expect(tests.dependencies).to eq([ TargetGraph.root_label ])
      expect(tests.phases).to eq(%w[review landing])
      expect(tests.required).to be(true)
      expect(tests.timeout_minutes).to eq(30)
      expect(tests.owner_config_path).to eq(".syrus.yml")
      expect(tests.metadata["failures"]).to eq("strict")

      audit = graph.target(TargetGraph::Label.parse("//:grade/audit"))
      expect(audit.required).to be(false)
      expect(audit.source_scope).to eq([ "Gemfile.lock" ])
      expect(audit.metadata["junit_output"]).to eq("tmp/audit.xml")
      expect(audit.metadata["description"]).to eq("Checks for known CVEs.")

      expect(graph.validate!).to be(true)
    end

    it "expands legacy ci: commands into a separate grader target scoped to the ci phase" do
      write(".syrus.yml", <<~YAML)
        grade:
          - name: tests
            run: bin/rspec
            ci: RUN_CI_ONLY_SPECS=true bin/rspec
      YAML

      graph = described_class.compile(@dir)

      review = graph.target(TargetGraph::Label.parse("//:grade/tests"))
      expect(review.command).to eq("bin/rspec")
      expect(review.phases).to eq(%w[review landing])

      ci = graph.target(TargetGraph::Label.parse("//:grade/tests-ci"))
      expect(ci.command).to eq("RUN_CI_ONLY_SPECS=true bin/rspec")
      expect(ci.phases).to eq(%w[ci])
      expect(ci.metadata["legacy_ci_command"]).to be(true)
      expect(ci.metadata["legacy_source_grader"]).to eq("tests")
    end

    it "compiles explicit formatters into formatter targets scoped by their files glob" do
      write(".syrus.yml", <<~YAML)
        formatters:
          - command: rubocop -a
            files: ["**/*.rb"]
          - command: eslint --fix
            files: ["**/*.ts", "**/*.tsx"]
      YAML

      graph = described_class.compile(@dir)

      rubocop = graph.target(TargetGraph::Label.parse("//:format/0"))
      expect(rubocop.kind).to eq("formatter")
      expect(rubocop.command).to eq("rubocop -a")
      expect(rubocop.source_scope).to eq([ "**/*.rb" ])
      expect(rubocop.dependencies).to eq([ TargetGraph.root_label ])

      eslint = graph.target(TargetGraph::Label.parse("//:format/1"))
      expect(eslint.command).to eq("eslint --fix")
      expect(eslint.source_scope).to eq([ "**/*.ts", "**/*.tsx" ])
    end

    it "does not compile a formatter target for the plugin-default opt-in (formatters: [])" do
      write(".syrus.yml", "formatters: []\n")

      graph = described_class.compile(@dir)

      expect(graph.targets.keys).to eq(%w[//:repo])
    end

    it "does not compile a formatter target when formatters is explicitly disabled" do
      write(".syrus.yml", "formatters: false\n")

      graph = described_class.compile(@dir)

      expect(graph.targets.keys).to eq(%w[//:repo])
    end

    it "compiles generated entries into generator targets, preserving codegen_ignore in metadata" do
      write(".syrus.yml", <<~YAML)
        generated:
          - command: bin/rails db:schema:dump
            sources: ["db/migrate/**/*.rb"]
            generates: ["db/schema.rb"]
            codegen_ignore: true
          - command: bin/generate-proto
            generates: ["gen/*.pb.go"]
      YAML

      graph = described_class.compile(@dir)

      schema = graph.target(TargetGraph::Label.parse("//:generate/0"))
      expect(schema.kind).to eq("generator")
      expect(schema.command).to eq("bin/rails db:schema:dump")
      expect(schema.source_scope).to eq([ "db/migrate/**/*.rb" ])
      expect(schema.metadata["generates"]).to eq([ "db/schema.rb" ])
      expect(schema.metadata["codegen_ignore"]).to be(true)

      proto = graph.target(TargetGraph::Label.parse("//:generate/1"))
      expect(proto.source_scope).to eq([])
      expect(proto.metadata["codegen_ignore"]).to be(false)
    end

    it "represents root prepare as a single prepare target with no wired dependents" do
      write(".syrus.yml", <<~YAML)
        prepare:
          - bundle install
          - npm ci
      YAML

      graph = described_class.compile(@dir)

      prepare = graph.target(TargetGraph::Label.parse("//:prepare"))
      expect(prepare.kind).to eq("prepare")
      expect(prepare.command).to eq("bundle install && npm ci")
      expect(prepare.metadata["commands"]).to eq([ "bundle install", "npm ci" ])
      expect(prepare.dependencies).to eq([])

      # Root prepare is the legacy pre-implementation baseline, not a
      # per-target dependency -- other root targets don't depend on it.
      expect(graph.targets.values.reject { |t| t.label == prepare.label }).to all(
        satisfy { |target| !target.depends_on?(prepare.label) }
      )
    end

    it "omits the prepare target when prepare is disabled or absent" do
      write(".syrus.yml", "prepare: false\n")
      expect(described_class.compile(@dir).targets.keys).to eq(%w[//:repo])

      write(".syrus.yml", "grade:\n  - name: tests\n    run: bin/rspec\n")
      expect(described_class.compile(@dir).target(TargetGraph::Label.parse("//:prepare"))).to be_nil
    end

    it "compiles no grader targets when legacy ci: expansion collides with another grader name" do
      write(".syrus.yml", <<~YAML)
        grade:
          - name: dup
            run: bin/one
            ci: bin/one-ci
          - name: dup-ci
            run: bin/two
      YAML

      graph = described_class.compile(@dir)

      expect(graph.targets.keys).to eq(%w[//:repo])
    end

    it "compiles nothing beyond the implicit root when .syrus.yml itself fails to parse" do
      write(".syrus.yml", <<~YAML)
        formatters:
          not_an_array: true
        grade:
          - name: tests
            run: bin/rspec
      YAML

      graph = described_class.compile(@dir)

      expect(graph.targets.keys).to eq(%w[//:repo])
    end

    it "produces a graph that validates cleanly end to end" do
      write(".syrus.yml", <<~YAML)
        prepare:
          - bundle install
        formatters:
          - command: rubocop -a
            files: ["**/*.rb"]
        generated:
          - command: bin/rails db:schema:dump
            generates: ["db/schema.rb"]
        grade:
          - name: tests
            run: bin/rspec
      YAML

      graph = described_class.compile(@dir)

      expect(graph.validate!).to be(true)
      expect(graph.cycles).to eq([])
    end
  end

  describe ".diagnose" do
    it "reports 'none' as the source and just the implicit root when no .syrus.yml is present" do
      diagnostics = described_class.diagnose(@dir)

      expect(diagnostics.source).to eq("none")
      expect(diagnostics.owner_config_path).to eq(".syrus.yml")
      expect(diagnostics.target_labels).to eq(%w[//:repo])
      expect(diagnostics.project_count).to eq(1)
      expect(diagnostics).not_to be_error
      expect(diagnostics.error).to be_nil
    end

    it "reports the compiled target labels for root legacy config, sorted for stable output" do
      write(".syrus.yml", <<~YAML)
        grade:
          - name: tests
            run: bin/rspec
        formatters:
          - command: rubocop -a
            files: ["**/*.rb"]
      YAML

      diagnostics = described_class.diagnose(@dir)

      expect(diagnostics.source).to eq(".syrus.yml")
      expect(diagnostics.target_labels).to eq(%w[//:format/0 //:grade/tests //:repo])
      expect(diagnostics.error).to be_nil
      expect(diagnostics.to_h).to include(
        "source" => ".syrus.yml",
        "target_count" => 3,
        "error" => nil
      )
    end

    it "names the owning .syrus.yml path in the error message when the config fails to parse" do
      write(".syrus.yml", <<~YAML)
        formatters:
          not_an_array: true
      YAML

      diagnostics = described_class.diagnose(@dir)

      expect(diagnostics).to be_error
      expect(diagnostics.error).to start_with(".syrus.yml:")
      # A parse failure degrades to the implicit root only -- never raises,
      # matching TargetGraph::Compiler.compile's existing non-fatal contract.
      expect(diagnostics.target_labels).to eq(%w[//:repo])
    end

    it "reports a graph validation failure through Diagnostics#error instead of raising" do
      # Legacy root-only compilation can't produce an invalid graph today
      # (see the ".compile" examples above), so exercise the
      # TargetGraph::Error rescue branch directly against the message
      # format TargetGraph#validate! actually produces (target label +
      # owning config path; see target_graph_spec.rb for that format).
      allow_any_instance_of(TargetGraph).to receive(:validate!)
        .and_raise(TargetGraph::ValidationError,
                   "target //:grade/broken (.syrus.yml) depends on unknown target //:missing")

      diagnostics = described_class.diagnose(@dir)

      expect(diagnostics).to be_error
      expect(diagnostics.error).to include(".syrus.yml")
      expect(diagnostics.error).to include("//:grade/broken")
      expect(diagnostics.error).to include("//:missing")
    end

    it "reports an unexpected non-TargetGraph::Error instead of raising, matching its documented never-raises contract" do
      allow(RepoGradePlan).to receive(:for).and_raise(StandardError, "boom")

      diagnostics = nil
      expect { diagnostics = described_class.diagnose(@dir) }.not_to raise_error

      expect(diagnostics).to be_error
      expect(diagnostics.error).to eq(".syrus.yml: boom")
    end
  end

  def write(rel, contents)
    path = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end
end
