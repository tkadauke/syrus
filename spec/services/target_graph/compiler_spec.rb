require "rails_helper"
require "tmpdir"

RSpec.describe TargetGraph::Compiler do
  around do |ex|
    Syrus::PluginRegistry.reset!
    Dir.mktmpdir("syrus-target-graph-compiler") { |dir| @dir = dir; ex.run }
    Syrus::PluginRegistry.reset!
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

    it "compiles a nested .syrus.yml's legacy sections into a directory-scoped project and targets" do
      write("cli/.syrus.yml", <<~YAML)
        prepare:
          - go mod download
        formatters:
          - command: gofmt -w .
            files: ["**/*.go"]
        generated:
          - command: go generate ./...
            generates: ["gen/*.go"]
        grade:
          - name: tests
            run: go test ./...
      YAML

      graph = described_class.compile(@dir)

      cli_project = graph.project("cli")
      expect(cli_project.path).to eq("cli")
      expect(cli_project.owner_config_path).to eq("cli/.syrus.yml")

      prepare = graph.target(TargetGraph::Label.parse("//cli:prepare"))
      expect(prepare.project_id).to eq("cli")
      expect(prepare.command).to eq("go mod download")
      expect(prepare.owner_config_path).to eq("cli/.syrus.yml")

      formatter = graph.target(TargetGraph::Label.parse("//cli:format/0"))
      expect(formatter.command).to eq("gofmt -w .")
      expect(formatter.source_scope).to eq([ "cli/**/*.go" ])
      expect(formatter.dependencies).to eq([ TargetGraph.root_label ])

      generator = graph.target(TargetGraph::Label.parse("//cli:generate/0"))
      expect(generator.command).to eq("go generate ./...")
      expect(generator.source_scope).to eq([ "cli/**/*" ])

      tests = graph.target(TargetGraph::Label.parse("//cli:grade/tests"))
      expect(tests.command).to eq("go test ./...")
      expect(tests.project_id).to eq("cli")
      expect(tests.owner_config_path).to eq("cli/.syrus.yml")
      expect(tests.source_scope).to eq([ "cli/**/*" ])

      # Root behavior is unaffected: still just the implicit root target.
      expect(graph.target(TargetGraph.root_label)).not_to be_nil
      expect(graph.validate!).to be(true)
    end

    describe "affected-file scope defaults (DOC-20 'First Implementation Slice' step 3)" do
      it "keeps root-only declarations repo-wide, with or without an explicit selector" do
        write(".syrus.yml", <<~YAML)
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

        formatter = graph.target(TargetGraph::Label.parse("//:format/0"))
        expect(formatter.source_scope).to eq([ "**/*.rb" ])

        generator = graph.target(TargetGraph::Label.parse("//:generate/0"))
        expect(generator.source_scope).to eq([])

        tests = graph.target(TargetGraph::Label.parse("//:grade/tests"))
        expect(tests.source_scope).to eq([])
      end

      it "scopes a nested declaration with no explicit selector to its own directory" do
        write("cli/.syrus.yml", "grade:\n  - name: tests\n    run: go test ./...\n")

        graph = described_class.compile(@dir)

        tests = graph.target(TargetGraph::Label.parse("//cli:grade/tests"))
        expect(tests.source_scope).to eq([ "cli/**/*" ])
      end

      it "resolves a nested declaration's own narrower file selector relative to its directory" do
        write("cli/.syrus.yml", <<~YAML)
          formatters:
            - command: gofmt -w .
              files: ["**/*.go"]
          generated:
            - command: go generate ./...
              sources: ["proto/**/*.proto"]
              generates: ["gen/*.go"]
          grade:
            - name: tests
              run: go test ./...
              when_files_changed: ["**/*.go"]
        YAML

        graph = described_class.compile(@dir)

        formatter = graph.target(TargetGraph::Label.parse("//cli:format/0"))
        expect(formatter.source_scope).to eq([ "cli/**/*.go" ])

        generator = graph.target(TargetGraph::Label.parse("//cli:generate/0"))
        expect(generator.source_scope).to eq([ "cli/proto/**/*.proto" ])

        tests = graph.target(TargetGraph::Label.parse("//cli:grade/tests"))
        expect(tests.source_scope).to eq([ "cli/**/*.go" ])
      end

      it "composes root and nested scopes additively: root stays repo-wide, nested stays directory-scoped" do
        write(".syrus.yml", <<~YAML)
          grade:
            - name: root-tests
              run: bin/rspec
              when_files_changed: ["app/**/*.rb"]
        YAML
        write("cli/.syrus.yml", "grade:\n  - name: tests\n    run: go test ./...\n")

        graph = described_class.compile(@dir)

        root_tests = graph.target(TargetGraph::Label.parse("//:grade/root-tests"))
        expect(root_tests.source_scope).to eq([ "app/**/*.rb" ])

        cli_tests = graph.target(TargetGraph::Label.parse("//cli:grade/tests"))
        expect(cli_tests.source_scope).to eq([ "cli/**/*" ])

        expect(graph.validate!).to be(true)
      end
    end

    it "loads nested config after root config, in deterministic path-sorted order" do
      write(".syrus.yml", "grade:\n  - name: root-tests\n    run: bin/rspec\n")
      write("zeta/.syrus.yml", "grade:\n  - name: tests\n    run: echo zeta\n")
      write("alpha/.syrus.yml", "grade:\n  - name: tests\n    run: echo alpha\n")

      graph = described_class.compile(@dir)

      expect(graph.targets.keys).to eq(
        %w[//:repo //:grade/root-tests //alpha:grade/tests //zeta:grade/tests]
      )
    end

    it "supports a nested .syrus.yml several directories below the root" do
      write("apps/desktop/.syrus.yml", "grade:\n  - name: tests\n    run: npm test\n")

      graph = described_class.compile(@dir)

      target = graph.target(TargetGraph::Label.parse("//apps/desktop:grade/tests"))
      expect(target.project_id).to eq("apps-desktop")
      expect(target.owner_config_path).to eq("apps/desktop/.syrus.yml")
    end

    it "compiles explicit targets and resolves relative dependency labels" do
      write("desktop/.syrus.yml", <<~YAML)
        targets:
          - name: renderer
            kind: library
            sources: ["src/**/*.ts"]
          - name: typecheck
            kind: grader
            run: npm run typecheck
            deps: [":renderer"]
            phases: [review, landing]
            required: true
            timeout_minutes: 20
      YAML

      graph = described_class.compile(@dir)

      renderer = graph.target(TargetGraph::Label.parse("//desktop:renderer"))
      expect(renderer.kind).to eq("library")
      expect(renderer.source_scope).to eq([ "desktop/src/**/*.ts" ])

      typecheck = graph.target(TargetGraph::Label.parse("//desktop:typecheck"))
      expect(typecheck.kind).to eq("grader")
      expect(typecheck.command).to eq("npm run typecheck")
      expect(typecheck.dependencies).to eq([ TargetGraph::Label.parse("//desktop:renderer") ])
      expect(typecheck.phases).to eq(%w[review landing])
      expect(typecheck.required).to be(true)
      expect(typecheck.timeout_minutes).to eq(20)
    end

    it "preserves command-list metadata for explicit prepare targets" do
      write("desktop/.syrus.yml", <<~YAML)
        targets:
          - name: deps
            kind: prepare
            run: npm ci
      YAML

      graph = described_class.compile(@dir)

      deps = graph.target(TargetGraph::Label.parse("//desktop:deps"))
      expect(deps.kind).to eq("prepare")
      expect(deps.command).to eq("npm ci")
      expect(deps.metadata["commands"]).to eq([ "npm ci" ])
    end

    it "wires legacy executable deps to generated graph node dependencies" do
      write(".syrus.yml", <<~YAML)
        targets:
          - name: app
            kind: library
            sources: ["app/**/*.rb"]
        formatters:
          - command: rubocop -a
            files: ["**/*.rb"]
            deps: [":app"]
        generated:
          - command: bin/rails db:schema:dump
            sources: ["db/migrate/**/*.rb"]
            generates: ["db/schema.rb"]
            deps: [":app"]
        grade:
          - name: tests
            run: bin/rspec
            deps: [":app"]
      YAML

      graph = described_class.compile(@dir)
      app = TargetGraph::Label.parse("//:app")

      expect(graph.target(TargetGraph::Label.parse("//:format/0")).dependencies).to eq([ TargetGraph.root_label, app ])
      expect(graph.target(TargetGraph::Label.parse("//:generate/0")).dependencies).to eq([ TargetGraph.root_label, app ])
      expect(graph.target(TargetGraph::Label.parse("//:grade/tests")).dependencies).to eq([ TargetGraph.root_label, app ])
    end

    it "keeps explicit executable targets alongside generated legacy executable targets in one scope" do
      write(".syrus.yml", <<~YAML)
        targets:
          - name: typecheck
            kind: grader
            run: npm run typecheck
            sources: ["app/frontend/**/*.ts"]
            phases: [review]
            required: true
          - name: bundle
            kind: builder
            run: npm run build
            sources: ["app/frontend/**/*"]
        formatters:
          - command: eslint --fix app/frontend
            files: ["app/frontend/**/*.ts"]
        generated:
          - command: npm run generate
            sources: ["schema/**/*.json"]
            generates: ["app/frontend/generated/**/*.ts"]
        grade:
          - name: tests
            run: npm test
            deps: [":typecheck", ":bundle"]
      YAML

      graph = described_class.compile(@dir)

      expect(graph.target(TargetGraph::Label.parse("//:typecheck")).kind).to eq("grader")
      expect(graph.target(TargetGraph::Label.parse("//:bundle")).kind).to eq("builder")
      expect(graph.target(TargetGraph::Label.parse("//:format/0")).kind).to eq("formatter")
      expect(graph.target(TargetGraph::Label.parse("//:generate/0")).kind).to eq("generator")

      tests = graph.target(TargetGraph::Label.parse("//:grade/tests"))
      expect(tests.dependencies).to eq([
        TargetGraph.root_label,
        TargetGraph::Label.parse("//:typecheck"),
        TargetGraph::Label.parse("//:bundle")
      ])
      expect(graph.validate!).to be(true)
    end

    it "imports explicitly configured build-system graph provider targets with provenance" do
      provider = fake_build_graph_provider(
        TargetGraph::Import.new(
          projects: [
            TargetGraph::Project.new(id: "bazel", label: "Bazel", path: "")
          ],
          targets: [
            TargetGraph::Target.new(
              label: TargetGraph::Label.parse("//bazel:app"),
              kind: "library",
              project_id: "bazel",
              source_scope: [ "src/**/*.rb" ],
              dependencies: [ TargetGraph::Label.parse("//:app") ]
            )
          ],
          diagnostics: { "query" => "//..." }
        )
      )
      Syrus::PluginRegistry.register(:build_system_graph_provider, provider)
      write(".syrus.yml", <<~YAML)
        targets:
          - name: app
            kind: library
            sources: ["app/**/*.rb"]
        target_graph:
          imports:
            - provider: fake
              config:
                query: //...
      YAML

      graph = described_class.compile(@dir)

      imported = graph.target(TargetGraph::Label.parse("//bazel:app"))
      expect(imported.kind).to eq("library")
      expect(imported.dependencies).to eq([ TargetGraph::Label.parse("//:app") ])
      expect(imported.owner_config_path).to include("target_graph.imports[0]")
      expect(imported.metadata["provenance"]).to include(
        "provider" => "fake",
        "provider_class" => "FakeBuildGraphProvider"
      )

      diagnostics = described_class.diagnose(@dir)
      expect(diagnostics.import_diagnostics).to contain_exactly(
        include(
          "provider" => "fake",
          "provider_class" => "FakeBuildGraphProvider",
          "status" => "imported",
          "project_ids" => [ "bazel" ],
          "target_labels" => [ "//bazel:app" ],
          "diagnostics" => { "query" => "//..." }
        )
      )
    end

    it "fails strictly when an explicit graph import names no enabled provider" do
      write(".syrus.yml", <<~YAML)
        target_graph:
          imports:
            - provider: missing
      YAML

      expect { described_class.compile(@dir) }.to raise_error(TargetGraph::ValidationError) do |error|
        expect(error.message).to include("build_system_graph_provider")
        expect(error.message).to include("missing")
      end
    end

    it "warns and continues when an explicit graph import opts into warning failures" do
      write(".syrus.yml", <<~YAML)
        target_graph:
          imports:
            - provider: missing
              failures: warn
      YAML

      graph = described_class.compile(@dir)
      expect(graph.targets.keys).to eq(%w[//:repo])

      diagnostics = described_class.diagnose(@dir)
      expect(diagnostics).to be_error
      expect(diagnostics.error).to include("missing")
      expect(diagnostics.import_diagnostics).to contain_exactly(
        include("status" => "error", "error" => include("missing"))
      )
    end

    it "applies warning failure policy to provider exceptions" do
      provider = fake_build_graph_provider(raise_error: RuntimeError.new("build file unreadable"))
      Syrus::PluginRegistry.register(:build_system_graph_provider, provider)
      write(".syrus.yml", <<~YAML)
        target_graph:
          imports:
            - provider: fake
              failures: warn
      YAML

      expect(described_class.compile(@dir).targets.keys).to eq(%w[//:repo])

      diagnostics = described_class.diagnose(@dir)
      expect(diagnostics.error).to include("build file unreadable")
    end

    it "raises a clear error when an explicit label collides with a generated legacy label" do
      write(".syrus.yml", <<~YAML)
        targets:
          - name: grade/tests
            kind: grader
            run: npm test
        grade:
          - name: tests
            run: bin/rspec
      YAML

      expect { described_class.compile(@dir) }.to raise_error(TargetGraph::ValidationError) do |error|
        expect(error.message).to include("//:grade/tests")
        expect(error.message).to include('explicit targets: "grade/tests"')
        expect(error.message).to include('legacy grade "tests"')
        expect(error.message).to include(".syrus.yml")
      end
    end

    it "raises a clear error when nested explicit and generated labels collide in their package" do
      write("cli/.syrus.yml", <<~YAML)
        targets:
          - name: format/0
            kind: formatter
            run: gofmt -w .
        formatters:
          - command: gofmt -w .
            files: ["**/*.go"]
      YAML

      expect { described_class.compile(@dir) }.to raise_error(TargetGraph::ValidationError) do |error|
        expect(error.message).to include("//cli:format/0")
        expect(error.message).to include('explicit targets: "format/0"')
        expect(error.message).to include("legacy formatters[0]")
        expect(error.message).to include("cli/.syrus.yml")
      end
    end

    it "raises a clear validation error for missing dependency labels" do
      write(".syrus.yml", <<~YAML)
        grade:
          - name: tests
            run: bin/rspec
            deps: [":missing"]
      YAML

      expect { described_class.compile(@dir) }.to raise_error(TargetGraph::ValidationError) do |error|
        expect(error.message).to include("//:grade/tests").and include("//:missing").and include(".syrus.yml")
      end
    end

    it "raises a clear validation error for obvious dependency cycles" do
      write(".syrus.yml", <<~YAML)
        targets:
          - name: one
            deps: [":two"]
          - name: two
            deps: [":one"]
      YAML

      expect { described_class.compile(@dir) }.to raise_error(TargetGraph::ValidationError, /dependency cycle/)
    end

    it "skips only the offending nested .syrus.yml when it fails to parse, keeping root and other nested files" do
      write(".syrus.yml", "grade:\n  - name: root-tests\n    run: bin/rspec\n")
      write("broken/.syrus.yml", "formatters:\n  not_an_array: true\n")
      write("ok/.syrus.yml", "grade:\n  - name: tests\n    run: echo ok\n")

      graph = described_class.compile(@dir)

      expect(graph.target(TargetGraph::Label.parse("//:grade/root-tests"))).not_to be_nil
      expect(graph.target(TargetGraph::Label.parse("//ok:grade/tests"))).not_to be_nil
      expect(graph.project("broken")).to be_nil
      expect(graph.validate!).to be(true)
    end

    it "raises a validation error naming both files when two nested directories resolve to the same project id" do
      write("foo/bar/.syrus.yml", "prepare: []\n")
      write("foo-bar/.syrus.yml", "prepare: []\n")

      expect { described_class.compile(@dir) }.to raise_error(TargetGraph::ValidationError) do |error|
        expect(error.message).to include("foo/bar/.syrus.yml")
        expect(error.message).to include("foo-bar/.syrus.yml")
      end
    end

    it "customizes the root project's label/kind from an explicit project: block" do
      write(".syrus.yml", <<~YAML)
        project:
          id: repo
          label: Syrus
          kind: rails_app
      YAML

      graph = described_class.compile(@dir)

      expect(graph.root_project.id).to eq("repo")
      expect(graph.root_project.label).to eq("Syrus")
      expect(graph.root_project.kind).to eq("rails_app")
      expect(graph.root_project.path).to eq("")
      expect(graph.root_project.owner_config_path).to eq(".syrus.yml")
      expect(graph.root_project).to be_root
    end

    it "defaults the root project's label to Repository when project: omits it" do
      write(".syrus.yml", "project:\n  kind: rails_app\n")

      graph = described_class.compile(@dir)

      expect(graph.root_project.label).to eq("Repository")
      expect(graph.root_project.kind).to eq("rails_app")
    end

    it "raises when the root project: block declares an id other than the root project id" do
      write(".syrus.yml", "project:\n  id: something-else\n")

      expect { described_class.compile(@dir) }.to raise_error(TargetGraph::ValidationError, /project\.id must be "repo"/)
    end

    it "raises when the root project: block declares a non-empty path" do
      write(".syrus.yml", "project:\n  path: somewhere\n")

      expect { described_class.compile(@dir) }.to raise_error(TargetGraph::ValidationError, /project\.path must be empty/)
    end

    it "overrides a nested project's id, label, and kind from an explicit project: block" do
      write("apps/desktop/.syrus.yml", <<~YAML)
        project:
          id: desktop
          label: Desktop App
          kind: desktop_app
        grade:
          - name: tests
            run: npm test
      YAML

      graph = described_class.compile(@dir)

      project = graph.project("desktop")
      expect(project.label).to eq("Desktop App")
      expect(project.kind).to eq("desktop_app")
      expect(project.path).to eq("apps/desktop")
      expect(project.owner_config_path).to eq("apps/desktop/.syrus.yml")

      target = graph.target(TargetGraph::Label.parse("//apps/desktop:grade/tests"))
      expect(target.project_id).to eq("desktop")
    end

    it "overrides a nested project's path scope metadata from an explicit project: block" do
      write("apps/desktop/.syrus.yml", "project:\n  path: apps\n")

      graph = described_class.compile(@dir)

      expect(graph.project("apps-desktop").path).to eq("apps")
    end

    it "resolves a nested directory-derived id collision by declaring an explicit project.id" do
      write("foo/bar/.syrus.yml", "project:\n  id: foo-bar-renamed\n")
      write("foo-bar/.syrus.yml", "prepare: []\n")

      graph = described_class.compile(@dir)

      expect(graph.projects.keys).to match_array(%w[repo foo-bar-renamed foo-bar])
    end

    it "raises when two nested project.id declarations collide with each other" do
      write("alpha/.syrus.yml", "project:\n  id: shared\n")
      write("beta/.syrus.yml", "project:\n  id: shared\n")

      expect { described_class.compile(@dir) }.to raise_error(TargetGraph::ValidationError) do |error|
        expect(error.message).to include("alpha/.syrus.yml")
        expect(error.message).to include("beta/.syrus.yml")
        expect(error.message).to include("shared")
      end
    end

    it "raises when a nested project.id collides with the root project id" do
      write("cli/.syrus.yml", "project:\n  id: repo\n")

      expect { described_class.compile(@dir) }.to raise_error(TargetGraph::ValidationError) do |error|
        expect(error.message).to include("cli/.syrus.yml")
        expect(error.message).to include(".syrus.yml")
        expect(error.message).to include('"repo"')
      end
    end

    it "does not infer a nested project from package.json, go.mod, or Rails conventions" do
      write("cli/go.mod", "module example.com/cli\n")
      write("api/package.json", "{}\n")
      write("app/models/.gitkeep", "")

      graph = described_class.compile(@dir)

      expect(graph.projects.keys).to eq(%w[repo])
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

    it "reports project/target labels compiled from a nested .syrus.yml alongside the root's own" do
      write(".syrus.yml", "grade:\n  - name: root-tests\n    run: bin/rspec\n")
      write("cli/.syrus.yml", "grade:\n  - name: tests\n    run: go test ./...\n")

      diagnostics = described_class.diagnose(@dir)

      expect(diagnostics.target_labels).to eq(%w[//:grade/root-tests //:repo //cli:grade/tests])
      expect(diagnostics.project_count).to eq(2)
      expect(diagnostics.error).to be_nil
    end

    it "names the offending nested file's path when it fails to parse, without failing the whole diagnosis" do
      write("broken/.syrus.yml", "formatters:\n  not_an_array: true\n")

      diagnostics = described_class.diagnose(@dir)

      expect(diagnostics).to be_error
      expect(diagnostics.error).to include("broken/.syrus.yml")
      # The rest of the graph -- here just the implicit root -- still compiles.
      expect(diagnostics.target_labels).to eq(%w[//:repo])
    end

    it "reports both a root and a nested parse failure together" do
      write(".syrus.yml", "formatters:\n  not_an_array: true\n")
      write("broken/.syrus.yml", "generated:\n  not_an_array: true\n")

      diagnostics = described_class.diagnose(@dir)

      expect(diagnostics).to be_error
      expect(diagnostics.error).to include(".syrus.yml:")
      expect(diagnostics.error).to include("broken/.syrus.yml:")
    end

    it "reports a duplicate nested project id declaration with both file paths, instead of raising" do
      write("foo/bar/.syrus.yml", "prepare: []\n")
      write("foo-bar/.syrus.yml", "prepare: []\n")

      diagnostics = nil
      expect { diagnostics = described_class.diagnose(@dir) }.not_to raise_error

      expect(diagnostics).to be_error
      expect(diagnostics.error).to include("foo/bar/.syrus.yml")
      expect(diagnostics.error).to include("foo-bar/.syrus.yml")
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

  def fake_build_graph_provider(result = nil, raise_error: nil)
    stub_const(
      "FakeBuildGraphProvider",
      Class.new do
        include Syrus::Plugin::BuildSystemGraphProvider

        define_singleton_method(:provider_key) { "fake" }
        define_singleton_method(:import_target_graph) do |repo_path:, config:|
          raise raise_error if raise_error

          @last_repo_path = repo_path
          @last_config = config
          result || TargetGraph::Import.new
        end
        define_singleton_method(:last_repo_path) { @last_repo_path }
        define_singleton_method(:last_config) { @last_config }
      end
    )
  end
end
