# frozen_string_literal: true

require "rails_helper"
require "open3"

RSpec.describe "Syrus grader configuration" do
  ROOT_GRAPH_CACHE = {}

  it "configures five rounds for every built-in review type" do
    config = SyrusYml.new(Rails.root.join(".syrus.yml").read).parse

    expect(config.adversarial_review.rounds).to eq(5)
    expect(config.security_review.rounds).to eq(5)
    expect(config.visual_review.rounds).to eq(5)
  end

  it "keeps the unland gate fast and smoke-only" do
    plan = LandingGraderPlan.effective(
      RepoGradePlan.for(Rails.root),
      trigger_kind: "unland",
      iteration: 1
    )

    expect(plan.graders.map(&:name)).to eq(%w[
      migration-collisions
      migration-lint
      thread-budget
      feature-slugs
      plugin-model-namespaces
      plugin-boundaries
      eager-load
      production-build-boot
      frontend-typecheck
    ])
    expect(plan.graders.find { |grader| grader.name == "frontend-typecheck" }).to have_attributes(
      command: "npm run typecheck",
      required: true
    )
  end

  it "checks the documented worker thread budget instead of the grader worker's concurrency" do
    plan = RepoGradePlan.for(Rails.root)
    grader = plan.graders.find { |candidate| candidate.name == "thread-budget" }

    expect(grader.command).to include("JOB_CONCURRENCY=6 bin/check-thread-budget")
  end

  it "onboards deterministic formatter commands for Syrus workflow autofixes" do
    config = SyrusYml.new(Rails.root.join(".syrus.yml").read).parse

    expect(config.formatters.map { |formatter| [ formatter.command, formatter.files ] }).to eq(
      [
        [
          "bundle exec rubocop -a",
          [
            "**/*.rb",
            "*.rb",
            ".rubocop.yml"
          ]
        ],
        [
          "npx eslint --fix app/frontend plugins/*/app/frontend",
          [
            "app/frontend/**/*.ts",
            "app/frontend/**/*.tsx",
            "plugins/*/app/frontend/**/*.ts",
            "plugins/*/app/frontend/**/*.tsx",
            "eslint.config.js",
            "eslint-rules/**/*.js"
          ]
        ],
        [
          "npm run format:frontend:changed",
          [
            "app/frontend/**/*.{ts,tsx,js,jsx,json,css,md,yml,yaml}",
            "plugins/*/app/frontend/**/*.{ts,tsx,js,jsx,json,css,md,yml,yaml}",
            "eslint-rules/**/*.js",
            "package.json",
            "package-lock.json",
            "tsconfig.json",
            "vite.config.ts"
          ]
        ],
        [
          "gofmt -w cli plugins/*/cli plugins/*/container",
          [
            "cli/**/*.go",
            "plugins/*/cli/**/*.go",
            "plugins/*/container/**/*.go"
          ]
        ]
      ]
    )
  end

  it "gives Rails-booting plugin model namespace checks enough grader headroom" do
    grader = RepoGradePlan.for(Rails.root).graders.find { |entry| entry.name == "plugin-model-namespaces" }

    expect(grader).not_to be_nil
    expect(grader.timeout_minutes).to eq(3)
  end

  # Shared frontend modules can make Vitest's related-test graph select nearly
  # the full SPA suite while also collecting focused coverage.
  it "gives focused React tests enough time for broad dependency graphs" do
    config = YAML.safe_load_file(Rails.root.join(".syrus.yml"))
    grader = config.fetch("grade").find { |entry| entry["name"] == "react-tests" }

    expect(grader.fetch("focused_timeout_minutes")).to eq(30)
  end

  it "allows every e2e shard to dismiss failures inherited from the base revision" do
    config = SyrusYml.new(Rails.root.join(".syrus.yml").read).parse
    shards = config.grade.steps.select { |step| step.name.start_with?("e2e-") }

    expect(shards.map(&:name)).to eq(%w[e2e-1-of-3 e2e-2-of-3 e2e-3-of-3])
    shards.each do |grader|
      expect(grader).to have_attributes(
        phases: [ "ci" ],
        failures: "allow_inherited",
        base_retry: SyrusYml::BaseRetry.new(strategy: "full_command", command: nil)
      )
    end
  end

  # Regression: the whole Playwright suite ran as one grader on one worker and
  # took 20-25 minutes against a 25-minute timeout. Every recent main-branch
  # repair timed out on it, which left the repair unable to prove main healthy.
  it "splits the e2e suite into Playwright shards that each run a distinct slice" do
    config = SyrusYml.new(Rails.root.join(".syrus.yml").read).parse
    shards = config.grade.steps.select { |step| step.name.start_with?("e2e-") }

    expect(shards.map(&:run)).to eq((1..3).map { |index| "E2E_ISOLATE=1 bin/test-e2e --shard=#{index}/3" })
    expect(shards.map(&:when_files_changed).uniq.size).to eq(1)
    expect(shards.map(&:metadata).uniq).to eq([ { "landing_parity" => false } ])
    expect(config.grade.steps.map(&:name)).not_to include("e2e")
  end

  # Regression: undeclared, the browser suite was charged one generic memory
  # unit while it used several gigabytes, and concurrent graders OOM-killed
  # worker pods. A declared working set is what admission reserves.
  it "declares the e2e shards' working set so admission reserves it" do
    shards = RepoGradePlan.for(Rails.root).graders.select { |grader| grader.name.start_with?("e2e-") }

    expect(shards.map { |grader| grader.resources.memory_bytes }).to eq([ 4.gigabytes ] * 3)
  end

  it "gives every CI-mode RSpec shard enough time to finish its serial examples" do
    shards = RepoGradePlan.for(Rails.root).graders.select { |entry| entry.name.start_with?("rspec-ci-") }

    expect(shards.map(&:name)).to eq((1..8).map { |index| "rspec-ci-#{index}-of-8" } + %w[rspec-ci-serial])
    shards.each { |grader| expect(grader).to have_attributes(phases: [ "ci" ], timeout_minutes: 150) }
  end

  it "selects the core RSpec suite for plugin boot-time Ruby but not plugin app code" do
    rspec = SyrusYml.new(Rails.root.join(".syrus.yml").read).parse.grade.steps.find { |step| step.name == "rspec" }

    expect(RepositoryContent::Glob.match?(rspec.when_files_changed, "plugins/scheduled_tasks/lib/scheduled_tasks/filter_extension.rb")).to be(true)
    expect(RepositoryContent::Glob.match?(rspec.when_files_changed, "plugins/scheduled_tasks/config/routes.rb")).to be(true)
    expect(RepositoryContent::Glob.match?(rspec.when_files_changed, "plugins/scheduled_tasks/app/services/scheduled_tasks/runner.rb")).to be(false)
    expect(RepositoryContent::Glob.match?(rspec.when_files_changed, "plugins/scheduled_tasks/app/frontend/routes/Calendar.tsx")).to be(false)
  end

  it "gives coverage-enabled CI React tests enough time to finish" do
    grader = RepoGradePlan.for(Rails.root).graders.find { |entry| entry.name == "react-tests-ci" }

    expect(grader).to have_attributes(
      phases: [ "ci" ],
      timeout_minutes: 30
    )
  end

  it "enforces the Whisper gateway tests with ffmpeg available" do
    grader = RepoGradePlan.for(Rails.root).graders.find { |entry| entry.name == "whisper-gateway-tests" }

    expect(grader).to have_attributes(
      command: "command -v ffmpeg >/dev/null && cd plugins/whisper_stt/container && GOWORK=off mise exec go@1.26.5 -- go test ./...",
      phases: %w[review landing ci],
      required: true,
      timeout_minutes: 3,
      when_files_changed: [
        "plugins/whisper_stt/container/**/*.go",
        "plugins/whisper_stt/container/go.mod",
        "plugins/whisper_stt/container/Dockerfile",
        "go.work",
        "Dockerfile"
      ]
    )
  end

  it "runs the Whisper image smoke in every grading phase" do
    grader = RepoGradePlan.for(Rails.root).graders.find { |entry| entry.name == "whisper-image-smoke" }

    expect(grader).to have_attributes(
      command: "bin/test-whisper-stt-image",
      phases: %w[review landing ci],
      required: true,
      timeout_minutes: 20,
      when_files_changed: [
        "plugins/whisper_stt/container/**",
        "bin/test-whisper-stt-image",
        "bin/publish-plugin-images"
      ]
    )
  end

  it "does not keep the old broad Go workspace backstop in the root config" do
    config = SyrusYml.new(Rails.root.join(".syrus.yml").read).parse

    grader = config.grade.steps.find { |step| step.name == "cli-go-workspace-backstop" }

    expect(grader).to be_nil
  end

  it "declares the root Rails app project while keeping global policy in the root config" do
    config = SyrusYml.new(Rails.root.join(".syrus.yml").read).parse
    graph = root_graph

    expect(config.project).to have_attributes(id: "repo", label: "Syrus App", kind: "rails_app")
    expect(config.prepare).to include(
      "bundle config set --local path vendor/bundle",
      "npm ci"
    )
    expect(config.deployment_stages.map(&:name)).to eq(%w[staging production public])

    expect(graph.root_project).to have_attributes(
      id: "repo",
      label: "Syrus App",
      kind: "rails_app",
      path: "",
      owner_config_path: ".syrus.yml"
    )
    expect(graph.root_project.preview).to eq(config.preview)
    expect(graph.root_project.visual_review).to eq(config.visual_review)
    coverage_key = "syrus_coverage.config"
    expect(graph.root_project.plugin_configurations[coverage_key].sources.map(&:artifact))
      .to eq(config.plugin_configurations[coverage_key].sources.map(&:artifact))
    expect(graph.root_project.plugin_configurations[coverage_key].threshold).to eq(config.plugin_configurations[coverage_key].threshold)
  end

  it "declares the CLI project and Go test target in cli/.syrus.yml" do
    config = SyrusYml.new(Rails.root.join("cli/.syrus.yml").read).parse

    expect(config.project).to have_attributes(id: "cli", label: "CLI", kind: "cli")
    expect(config.prepare).to eq([ "GOWORK=off mise exec go@1.26.5 -- go mod download" ])

    grader = config.grade.steps.find { |step| step.name == "go-tests" }
    expect(grader).to have_attributes(
      run: "mise exec go@1.26.5 -- go test ./...",
      phases: %w[review landing ci],
      required: true,
      timeout_minutes: 5,
      when_files_changed: [ "**/*.go", "go.mod", "go.sum", "Makefile" ]
    )
  end

  it "selects independent browser and terminal visual-review targets from the root config" do
    config = SyrusYml.new(Rails.root.join(".syrus.yml").read).parse
    targets = config.visual_review.targets

    expect(targets.map(&:provider)).to eq(%w[browser cli_tui])
    expect(RepositoryContent::Glob.match?(config.visual_review.when_files_changed, "cli/cmd/inbox.go")).to be(true)
    expect(RepositoryContent::Glob.match?(config.visual_review.when_files_changed, "app/frontend/routes/JobDetail.tsx")).to be(true)
    expect(RepositoryContent::Glob.match?(config.visual_review.when_files_changed, "README.md")).to be(false)
    browser_notes = targets.find { |target| target.provider == "browser" }.review_notes
    expect(browser_notes).to include("/admin/tool_cards", "running Bash", "exactly one visual line", "automatically needs_work")
    expect(targets.find { |target| target.provider == "cli_tui" }).to have_attributes(
      environment: have_attributes(
        static: {},
        command: have_attributes(
          argv: [ "bin/visual-review-env" ],
          inputs: %w[run_api_endpoint run_api_credential],
          allow_output: %w[SYRUS_CLI_URL SYRUS_CLI_INVOCATION_CONTEXT]
        )
      ),
      build: { "command" => "mise exec go@1.26.5 -- go build -o tmp/syrus-visual-review ./cli" },
      launch: { "command" => "tmp/syrus-visual-review inbox --watch" },
      dimensions: { "columns" => 100, "rows" => 32 },
      when_files_changed: [ "cli/**/*.go" ]
    )

    unavailable_previews = App::VisualReviewProjects::Result.new(choices: [], unavailable_reason: "not_needed")
    selected_for = lambda do |changed_file|
      App::VisualReviewRuntimeTargets.call(
        workspace_path: Rails.root,
        changed_files: [ changed_file ],
        preview_projects: unavailable_previews
      ).map(&:provider)
    end

    expect(selected_for.call("cli/cmd/inbox.go")).to eq([ "cli_tui" ])
    expect(selected_for.call("app/frontend/routes/JobDetail.tsx")).to eq([ "browser" ])
    expect(selected_for.call("README.md")).to be_empty
  end

  it "validates static and generated visual-review environment declarations" do
    config = SyrusYml.new(<<~YAML).parse
      visual_review:
        targets:
          - provider: cli_tui
            environment:
              static:
                APP_MODE: visual-review
                FEATURE_ENABLED: true
              command:
                argv: [bin/review-env]
                inputs: [run_api_endpoint]
                allow_output: [APP_URL]
    YAML

    expect(config.visual_review.targets.first.environment).to have_attributes(
      static: { "APP_MODE" => "visual-review", "FEATURE_ENABLED" => "true" },
      command: have_attributes(argv: [ "bin/review-env" ], inputs: [ "run_api_endpoint" ], allow_output: [ "APP_URL" ])
    )

    [
      "static: { PATH: /tmp/bin }",
      "static: { BAD-NAME: value }",
      "static: { NESTED: { value: no } }",
      "command: { argv: [bin/env], allow_output: [LD_PRELOAD] }"
    ].each do |environment|
      expect do
        SyrusYml.new(<<~YAML).parse
          visual_review:
            targets:
              - provider: cli_tui
                environment:
                  #{environment}
        YAML
      end.to raise_error(SyrusYml::ParseError)
    end
  end

  it "requires adversarial review to enforce the collapsed tool-card design lock" do
    config = SyrusYml.new(Rails.root.join(".syrus.yml").read).parse
    criteria = config.adversarial_review.criteria.join("\n")

    expect(criteria).to include(
      "collapsed tool-card header",
      "one visual line",
      "hides or stacks pills",
      "fixture manipulation",
      "explicit written approval from Thomas Kadauke"
    )
  end

  it "fails clearly for malformed or unavailable terminal visual-review configuration" do
    expect do
      SyrusYml.new(<<~YAML).parse
        visual_review:
          targets:
            - name: CLI TUI
              provider: cli_tui
              dimensions: { columns: 0, rows: 32 }
      YAML
    end.to raise_error(SyrusYml::ParseError, /visual_review\.targets\[0\]\.dimensions: values must be positive integers/)

    target = App::VisualReviewRuntimeTargets.call(
      workspace_path: Rails.root,
      changed_files: [ "cli/cmd/inbox.go" ],
      preview_projects: App::VisualReviewProjects::Result.new(choices: [], unavailable_reason: "not_needed")
    ).sole
    run = Factories.job.runs.last
    allow(RuntimeSessionProviders).to receive(:for).with("cli_tui").and_raise(
      RuntimeSessionProviders::ConfigurationError,
      'Unknown runtime session provider: "cli_tui"'
    )

    expect { VisualReviewRuntimeSession.new(run: run, target: target).start! }
      .to raise_error(RuntimeSessionProviders::ConfigurationError, /Unknown runtime session provider: "cli_tui"/)
    expect(run.runtime_sessions).to be_empty
  end

  it "declares the desktop project and scoped desktop validation targets in desktop/.syrus.yml" do
    config = SyrusYml.new(Rails.root.join("desktop/.syrus.yml").read).parse

    expect(config.project).to have_attributes(id: "desktop", label: "Desktop App", kind: "desktop_app")
    expect(config.prepare).to eq([ "npm ci" ])
    expect(config.preview.start).to eq("npm exec vite -- --host 0.0.0.0 --port $PORT")
    expect(config.visual_review).to have_attributes(enabled: true, rounds: 2)
    expect(config.plugin_configurations["syrus_coverage.config"].sources.first.artifact).to eq("coverage/lcov.info")

    graph = root_graph
    expect(graph.target("//desktop:renderer-build").command).to eq("npm run build:renderer")
    expect(graph.target("//desktop:main-build").command).to eq("npm run build:main")

    grader = config.grade.steps.find { |step| step.name == "typecheck" }
    expect(grader).to have_attributes(
      run: "npm --prefix desktop run typecheck",
      phases: %w[review landing ci],
      required: true,
      timeout_minutes: 10
    )
    expect(grader.when_files_changed).to include("src/**/*.ts", "electron/**/*.ts", "package-lock.json")
  end

  it "selects the CLI target and the executable root backstop for core CLI changes" do
    graph = root_graph

    cli_prepare = graph.target("//cli:prepare")
    cli_tests = graph.affected("//cli:grade/go-tests", changed_files: [ "cli/cmd/jobs.go" ])

    expect(cli_prepare.command).to eq("GOWORK=off mise exec go@1.26.5 -- go mod download")
    expect(cli_tests.affected).to be(true)
  end

  it "keeps the CLI prepare target from mutating Go workspace sums" do
    skip "mise is required for the configured CLI prepare target" unless system("command -v mise >/dev/null 2>&1")

    config = SyrusYml.new(Rails.root.join("cli/.syrus.yml").read).parse
    command = config.prepare.fetch(0)

    Dir.mktmpdir("syrus-cli-prepare-hermetic") do |dir|
      tmp = Pathname.new(dir)
      copy_cli_prepare_fixture(tmp)

      system("git", "init", "-q", "-b", "main", chdir: tmp.to_s, exception: true)
      system("git", "config", "user.email", "test@example.com", chdir: tmp.to_s, exception: true)
      system("git", "config", "user.name", "Test", chdir: tmp.to_s, exception: true)
      system("git", "add", ".", chdir: tmp.to_s, exception: true)
      system("git", "commit", "-q", "-m", "prepare fixture", chdir: tmp.to_s, exception: true)

      output, status = Open3.capture2e("bash", "-lc", command, chdir: tmp.join("cli").to_s)
      expect(status).to be_success, output

      status_output, status_check = Open3.capture2e("git", "status", "--porcelain", "--", "go.work.sum", "cli/go.sum", chdir: tmp.to_s)
      expect(status_check).to be_success, status_output
      expect(status_output).to eq("")
    end
  end

  it "selects the union of Rails app and CLI project primitives for mixed app and CLI changes" do
    graph = root_graph
    changed_files = [ "app/services/target_graph.rb", "cli/cmd/jobs.go" ]

    app_focused_specs = graph.affected("//:grade/rspec-focused", changed_files: changed_files)
    cli_tests = graph.affected("//cli:grade/go-tests", changed_files: changed_files)

    expect(app_focused_specs.affected).to be(true)
    expect(app_focused_specs.target.project_id).to eq("repo")
    expect(cli_tests.affected).to be(true)
    expect(cli_tests.target.project_id).to eq("cli")
  end

  it "selects desktop targets without treating the root React grader as a desktop backstop" do
    graph = root_graph

    typecheck = graph.affected("//desktop:grade/typecheck", changed_files: [ "desktop/src/App.tsx" ])
    renderer_build = graph.affected("//desktop:renderer-build", changed_files: [ "desktop/src/App.tsx" ])
    root_react_focused = graph.affected("//:grade/react-tests-focused", changed_files: [ "desktop/src/App.tsx" ])

    expect(graph.project("desktop")).to have_attributes(
      label: "Desktop App",
      kind: "desktop_app",
      path: "desktop",
      owner_config_path: "desktop/.syrus.yml"
    )
    expect(typecheck.affected).to be(true)
    expect(renderer_build.affected).to be(true)
    expect(root_react_focused.affected).to be(false)
  end

  it "selects the union of Rails app and desktop project primitives for mixed app and desktop changes" do
    graph = root_graph
    changed_files = [ "app/frontend/routes/Dashboard.tsx", "desktop/src/App.tsx" ]

    app_visual = App::VisualReviewProjects.call(workspace_path: Rails.root, changed_files: changed_files)
    app_react_focused = graph.affected("//:grade/react-tests-focused", changed_files: changed_files)
    desktop_typecheck = graph.affected("//desktop:grade/typecheck", changed_files: changed_files)
    desktop_renderer_build = graph.affected("//desktop:renderer-build", changed_files: changed_files)

    expect(app_visual.choices.map(&:id)).to match_array(%w[repo desktop])
    expect(app_react_focused.affected).to be(true)
    expect(app_react_focused.reason).to eq("own source scope matched a changed file")
    expect(desktop_typecheck.affected).to be(true)
    expect(desktop_renderer_build.affected).to be(true)
  end

  it "scopes root framework graders to the root Syrus app project" do
    config = SyrusYml.new(Rails.root.join(".syrus.yml").read).parse
    rspec = config.grade.steps.find { |step| step.name == "rspec" }
    rspec_focused = config.grade.steps.find { |step| step.name == "rspec-focused" }
    grader = config.grade.steps.find { |step| step.name == "react-tests-focused" }

    # The generated catalogs are inputs to the suite, not only its output:
    # spec/docs/surface_catalogs_spec.rb and spec/docs/metrics_catalog_spec.rb
    # read them and fail on drift, so a docs-only diff must not skip rspec.
    catalog_scope = %w[
      config/syrus_docs/**/*.md
      docs/engineering/**/*.md
      website/src/content/docs/generated/**/*.md
      docs/metrics-catalog.md
    ]
    # Plugin boot-time Ruby registers into core registries the suite asserts.
    plugin_boot_scope = %w[plugins/*/lib/**/*.rb plugins/*/config/**/*.rb]
    core_scope = %w[app/**/*.rb lib/**/*.rb spec/**/*.rb] + plugin_boot_scope + catalog_scope
    expect(rspec.when_files_changed).to eq(core_scope)
    expect(rspec_focused.when_files_changed).to eq(core_scope)
    expect(grader.when_files_changed).to eq([
      "app/frontend/**/*.js",
      "app/frontend/**/*.jsx",
      "app/frontend/**/*.ts",
      "app/frontend/**/*.tsx",
      "package.json",
      "package-lock.json",
      "tsconfig.json",
      "vite.config.ts"
    ])
  end

  it "expands work-engine simulations as one fixed full-path RSpec grader" do
    config = SyrusYml.new(Rails.root.join(".syrus.yml").read).parse
    matching_graders = config.grade.steps.select { |step| step.name.start_with?("work-engine-simulations") }
    grader = matching_graders.sole
    target = root_graph.target("//:grade/work-engine-simulations")

    expect(grader).to have_attributes(
      phases: %w[review landing ci],
      required: true,
      timeout_minutes: 30,
      failures: "allow_inherited",
      base_retry: SyrusYml::BaseRetry.new(strategy: "plugin", command: nil),
      junit_output: ".syrus/grade-output/work-engine-simulations-junit.xml"
    )
    expect(grader.run).to include("bundle exec rspec")
    expect(grader.run).to include("spec/services/work_engine/simulation/scenario_runner_spec.rb")
    expect(grader.run).not_to include("bin/simulator")
    expect(grader.run).not_to include(".syrus/rspec-focused-files")
    expect(grader.run).not_to include("RUN_CI_ONLY_SPECS=true")
    expect(grader.metadata).to include(
      "grader_type" => "rspec",
      "grader_framework" => "rspec",
      "grader_mode" => "full",
      "result_outputs" => [
        { "artifact" => ".syrus/grade-output/work-engine-simulations-junit.xml", "format" => "junit" }
      ]
    )
    expect(grader.when_files_changed).to include(
      "app/services/work_engine/**",
      "spec/services/work_engine/**",
      "spec/fixtures/work_engine_simulations/**"
    )
    expect(target).to have_attributes(
      command: grader.run,
      phases: %w[review landing ci],
      required: true,
      timeout_minutes: 30
    )
    expect(target.metadata).to include(
      "junit_output" => ".syrus/grade-output/work-engine-simulations-junit.xml",
      "base_retry" => { strategy: "plugin", command: nil },
      "grader_type" => "rspec",
      "grader_mode" => "full"
    )
  end

  it "declares every bundled plugin as an individual plugin project with a local grader" do
    # Typed graders are resolved through enabled plugin providers. Establish
    # that prerequisite here instead of inheriting mutable suite-wide plugin
    # record state from examples that exercise enable and disable cascades.
    %w[ruby javascript].each do |plugin_name|
      PluginRecord.find_by!(name: plugin_name).update!(enabled: true)
    end
    Syrus::PluginRegistry.clear_plugin_record_cache!

    graph = root_graph
    plugin_dirs = Rails.root.join("plugins").children.select(&:directory?).map { |path| path.basename.to_s }.sort
    frontend_test_plugins = plugin_dirs.select do |plugin|
      Dir.glob(Rails.root.join("plugins/#{plugin}/app/frontend/**/*.{test,spec}.{ts,tsx}").to_s, File::FNM_EXTGLOB).any?
    end

    plugin_projects = graph.projects.values.select { |project| project.kind == "plugin" }

    expect(plugin_projects.map(&:id).sort).to eq(plugin_dirs)
    plugin_projects.each do |project|
      expect(project.path).to eq("plugins/#{project.id}")
      expect(project.owner_config_path).to eq("plugins/#{project.id}/.syrus.yml")

      grader = graph.target("//plugins/#{project.id}:grade/rspec")
      expect(grader).not_to be_nil
      expect(grader.project_id).to eq(project.id)
      expect(grader.command).to include("bundle exec rspec")
      expect(grader.source_scope).to include(
        "plugins/#{project.id}/**/*.rb",
        "plugins/#{project.id}/*.gemspec"
      )

      vitest = graph.target("//plugins/#{project.id}:grade/vitest")
      if frontend_test_plugins.include?(project.id)
        expect(vitest).not_to be_nil
        expect(vitest.project_id).to eq(project.id)
        expect(vitest.command).to include("run_vitest run plugins/#{project.id}/app/frontend")
        expect(vitest.metadata["junit_output"]).to eq(".syrus/grade-output/plugins-#{project.id}-vitest-junit.xml")
        expect(vitest.source_scope).to include(
          "plugins/#{project.id}/**/*.ts",
          "plugins/#{project.id}/**/*.tsx",
          "plugins/#{project.id}/package.json"
        )
        expect(vitest.dependencies).to eq([ TargetGraph.root_label ])
      else
        expect(vitest).to be_nil
      end

      # A plugin's Go lives in an independently shipped executable module
      # (cli/) or in its service container (container/). Neither is imported
      # by the core CLI.
      go_tests = graph.target("//plugins/#{project.id}:grade/go-tests")
      go_dir = %w[cli container].find { |dir| Rails.root.join("plugins/#{project.id}/#{dir}/go.mod").exist? }
      if go_dir
        expect(go_tests).not_to be_nil
        expect(go_tests.command).to include("cd plugins/#{project.id}/#{go_dir} && ")
        expect(go_tests.command).to include("go test ./...")
        expect(go_tests.command).to include("{ go list ./... >/dev/null 2>&1 || export GOWORK=off; }")
        expect(go_tests.command).to end_with("go test ./...'")
        expect(go_tests.source_scope).to include(
          "plugins/#{project.id}/#{go_dir}/**/*.go",
          "plugins/#{project.id}/#{go_dir}/go.mod"
        )
      else
        expect(go_tests).to be_nil
      end
    end
  end

  it "uses plugin dependency declarations as target graph dependency edges" do
    graph = root_graph

    expect(graph.affected("//plugins/rails:grade/rspec", changed_files: [ "plugins/ruby/lib/ruby.rb" ])).to have_attributes(
      affected: true,
      reason: "dependency //plugins/ruby:grade/rspec source scope matched a changed file"
    )
    expect(graph.affected("//plugins/django:grade/rspec", changed_files: [ "plugins/python/lib/python.rb" ])).to have_attributes(
      affected: true,
      reason: "dependency //plugins/python:grade/rspec source scope matched a changed file"
    )
    expect(graph.affected("//plugins/runtime_terminal:grade/rspec", changed_files: [ "plugins/terminal/lib/terminal.rb" ])).to have_attributes(
      affected: true,
      reason: "dependency //plugins/terminal:grade/rspec source scope matched a changed file"
    )
  end

  # A plugin grader's only other edges are its sibling plugins and `//:repo`,
  # whose empty source scope TargetGraph#affected ignores on purpose. So
  # without this one, editing the very extension point a plugin implements
  # selected no plugin grader at all, and a broken plugin landed green.
  it "selects every plugin's specs when the core plugin API changes" do
    graph = root_graph
    plugin_rspec_labels = Dir[Rails.root.join("plugins/*/.syrus.yml")].map do |path|
      "//plugins/#{File.basename(File.dirname(path))}:grade/rspec"
    end

    expect(plugin_rspec_labels.size).to be >= 40
    [ "lib/syrus/plugin/test_evidence.rb", "lib/syrus/plugin_registry.rb", "lib/syrus/plugin/manifest.rb" ].each do |file|
      expect(graph.affected("//plugins/test_insights:grade/rspec", changed_files: [ file ])).to have_attributes(
        affected: true,
        reason: "dependency //:plugin-api source scope matched a changed file"
      )
    end
    plugin_rspec_labels.each do |label|
      expect(graph.affected(label, changed_files: [ "lib/syrus/plugin/manifest.rb" ]).affected).to be(true), label
    end

    # Narrow on purpose: ordinary core code is not the plugin contract, and
    # putting it in scope would run every plugin's specs on nearly every PR.
    expect(graph.affected("//plugins/test_insights:grade/rspec", changed_files: [ "app/models/job.rb" ]).affected).to be(false)
  end

  it "scopes the website build grader to website and website deploy changes" do
    config = SyrusYml.new(Rails.root.join("website/.syrus.yml").read, project_path: "website").parse
    graph = root_graph
    grader = config.grade.steps.find { |step| step.name == "build" }

    expect(grader.when_files_changed).to contain_exactly("**/*")
    expect(graph.affected("//website:grade/build", changed_files: [ "website/src/site-pages/Home.tsx" ]).affected).to be(true)
    expect(graph.affected("//website:grade/build", changed_files: [ ".github/workflows/deploy-website.yml" ])).to have_attributes(
      affected: true,
      reason: "dependency //:website-deploy-workflow source scope matched a changed file"
    )
    expect(graph.affected("//website:grade/build", changed_files: [ "app/models/job.rb" ]).affected).to be(false)
  end

  it "selects the Website preview and relative visual-review policy only for rendered website changes" do
    config = SyrusYml.new(Rails.root.join("website/.syrus.yml").read, project_path: "website").parse
    graph = root_graph
    website = graph.project("website")

    expect(website).to have_attributes(
      label: "Website",
      path: "website",
      owner_config_path: "website/.syrus.yml"
    )
    expect(website.preview).to eq(config.preview)
    expect(website.preview).to have_attributes(
      start: "npm run dev -- --hostname 0.0.0.0 --port $PORT",
      health_check: "/"
    )
    expect(website.visual_review).to eq(config.visual_review)
    expect(website.visual_review).to have_attributes(enabled: true, rounds: 2)
    expect(website.visual_review.when_files_changed).to include(
      "src/app/**/*",
      "src/content/docs/**/*.md",
      "src/content/blog/**/*.md",
      "components/**/*",
      "lib/locales.ts",
      "lib/marketing.ts",
      "public/**/*",
      "package.json",
      "package-lock.json",
      "scripts/sync-plugin-icons.mjs"
    )

    docs_review = App::VisualReviewProjects.call(
      workspace_path: Rails.root,
      changed_files: [ "website/src/content/docs/dogfooding.md" ]
    )
    expect(docs_review.choices.map(&:id)).to eq([ "website" ])
    expect(docs_review.when_files_changed).to include(
      "website/src/content/docs/**/*.md",
      "website/components/**/*"
    )
    expect(docs_review.seed_notes).to include("/docs/dogfooding", "/de/", "/blog")
    expect(RepositoryContent::Glob.match?(docs_review.when_files_changed, "website/src/content/docs/dogfooding.md")).to be(true)
    expect(RepositoryContent::Glob.match?(docs_review.when_files_changed, "website/package-lock.json")).to be(true)
    expect(RepositoryContent::Glob.match?(docs_review.when_files_changed, "website/scripts/sync-plugin-icons.mjs")).to be(true)
    expect(RepositoryContent::Glob.match?(docs_review.when_files_changed, "website/lib/marketing.test.ts")).to be(false)

    backend_review = App::VisualReviewProjects.call(
      workspace_path: Rails.root,
      changed_files: [ "app/models/job.rb" ]
    )
    expect(backend_review.choices.map(&:id)).to eq([ "repo" ])
  end

  # migration-baselines ran `bin/rails db:create` with no bundle installed and
  # died in two seconds with "Could not find rails-8.1.3.1, propshaft-...",
  # i.e. the whole bundle missing. It is a REQUIRED grader in the landing and
  # ci phases, so it held main red and blocked landing. It only ever passed
  # when some earlier grader happened to install the bundle first -- an
  # ordering dependency, not a contract.
  it "makes every Rails-booting grader install its own bundle" do
    config = SyrusYml.new(Rails.root.join(".syrus.yml").read).parse

    rails_booting = config.grade.steps.select do |step|
      step.run.to_s.match?(%r{bin/check-primary-migration-baselines|bin/check-plugin-model-namespaces|bin/check-plugin-boundaries|bin/rails|bin/rspec})
    end

    expect(rails_booting).not_to be_empty
    missing = rails_booting.reject { |step| step.run.include?("bundle check") || step.run.include?("bundle install") }

    expect(missing.map(&:name)).to eq([]),
      "these graders boot Rails but never install a bundle, so they depend on " \
      "another grader having run first: #{missing.map(&:name).join(', ')}"
  end

  it "gives the full-tree plugin boundary audit enough time under shared-worker load" do
    config = SyrusYml.new(Rails.root.join(".syrus.yml").read).parse
    grader = config.grade.steps.find { |step| step.name == "plugin-boundaries" }

    expect(grader.timeout_minutes).to be >= 8
  end

  def root_graph
    enabled_plugins = PluginRecord.order(:name).select(&:effective_enabled?).map(&:name)
    ROOT_GRAPH_CACHE[enabled_plugins] ||= TargetGraph::Compiler.compile(Rails.root)
  end

  def copy_cli_prepare_fixture(destination)
    copy_files(destination, "cli", %w[go.mod go.sum])
  end

  def copy_files(destination, directory, filenames)
    filenames.each do |filename|
      source = Rails.root.join(directory, filename)
      target = destination.join(directory, filename)
      FileUtils.mkdir_p(target.dirname)
      FileUtils.cp(source, target)
    end
  end
end
