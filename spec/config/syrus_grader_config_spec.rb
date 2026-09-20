# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Syrus grader configuration" do
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
          "gofmt -w cli plugins/*/cli",
          [
            "cli/**/*.go",
            "plugins/*/cli/**/*.go"
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

  it "keeps an executable Go workspace backstop in the root config" do
    config = SyrusYml.new(Rails.root.join(".syrus.yml").read).parse

    grader = config.grade.steps.find { |step| step.name == "cli-go-workspace-backstop" }

    # The core CLI module has project metadata in cli/.syrus.yml, but normal
    # grader fanout still materializes only root RepoGradePlan entries. Keep
    # this broad executable backstop until nested grader targets run directly.
    expect(grader).to have_attributes(
      run: %(mise exec go@1.26.5 -- sh -c 'go test $(go list -m -f "{{.Dir}}/...")'),
      phases: %w[review landing ci],
      required: true,
      timeout_minutes: 5
    )
    expect(grader.when_files_changed).to include(
      "cli/**/*.go",
      "cli/go.mod",
      "cli/go.sum",
      "cli/Makefile",
      "go.work",
      "plugins/*/cli/**/*.go",
      "plugins/*/cli/go.mod",
      "bin/release-cli",
      "desktop/scripts/stage-cli.mjs"
    )
  end

  it "declares the root Rails app project while keeping global policy in the root config" do
    config = SyrusYml.new(Rails.root.join(".syrus.yml").read).parse
    graph = TargetGraph::Compiler.compile(Rails.root)

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
    expect(graph.root_project.coverage.sources.map(&:artifact)).to eq(config.coverage.sources.map(&:artifact))
    expect(graph.root_project.coverage.threshold).to eq(config.coverage.threshold)
    expect(graph.root_project.coverage.project_id).to eq("repo")
  end

  it "declares the CLI project and Go test target in cli/.syrus.yml" do
    config = SyrusYml.new(Rails.root.join("cli/.syrus.yml").read).parse

    expect(config.project).to have_attributes(id: "cli", label: "CLI", kind: "cli")
    expect(config.prepare).to eq([ "mise exec go@1.26.5 -- go mod download" ])

    grader = config.grade.steps.find { |step| step.name == "go-tests" }
    expect(grader).to have_attributes(
      run: "mise exec go@1.26.5 -- go test ./...",
      phases: %w[review landing ci],
      required: true,
      timeout_minutes: 5,
      when_files_changed: [ "**/*.go", "go.mod", "go.sum", "Makefile" ]
    )
  end

  it "declares the desktop project and scoped desktop validation targets in desktop/.syrus.yml" do
    config = SyrusYml.new(Rails.root.join("desktop/.syrus.yml").read).parse

    expect(config.project).to have_attributes(id: "desktop", label: "Desktop App", kind: "desktop_app")
    expect(config.prepare).to eq([ "npm ci" ])
    expect(config.preview.start).to eq("npm exec vite -- --host 127.0.0.1 --port $PORT")
    expect(config.visual_review).to have_attributes(enabled: true, rounds: 2)
    expect(config.coverage.sources.first.artifact).to eq("coverage/lcov.info")

    graph = TargetGraph::Compiler.compile(Rails.root)
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
    graph = TargetGraph::Compiler.compile(Rails.root)

    cli_prepare = graph.target("//cli:prepare")
    cli_tests = graph.affected("//cli:grade/go-tests", changed_files: [ "cli/cmd/jobs.go" ])
    root_backstop = graph.affected("//:grade/cli-go-workspace-backstop", changed_files: [ "cli/cmd/jobs.go" ])
    plugin_cli = graph.affected("//:grade/cli-go-workspace-backstop", changed_files: [ "plugins/example/cli/cmd/example.go" ])

    expect(cli_prepare.command).to eq("mise exec go@1.26.5 -- go mod download")
    expect(cli_tests.affected).to be(true)
    expect(root_backstop.affected).to be(true)
    expect(plugin_cli.affected).to be(true)
  end

  it "selects the union of Rails app and CLI project primitives for mixed app and CLI changes" do
    graph = TargetGraph::Compiler.compile(Rails.root)
    changed_files = [ "app/services/target_graph.rb", "cli/cmd/jobs.go" ]

    app_focused_specs = graph.affected("//:grade/rspec-focused", changed_files: changed_files)
    cli_tests = graph.affected("//cli:grade/go-tests", changed_files: changed_files)
    root_backstop = graph.affected("//:grade/cli-go-workspace-backstop", changed_files: changed_files)

    expect(app_focused_specs.affected).to be(true)
    expect(app_focused_specs.target.project_id).to eq("repo")
    expect(cli_tests.affected).to be(true)
    expect(cli_tests.target.project_id).to eq("cli")
    expect(root_backstop.affected).to be(true)
  end

  it "selects desktop targets without treating the root React grader as a desktop backstop" do
    graph = TargetGraph::Compiler.compile(Rails.root)

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
    graph = TargetGraph::Compiler.compile(Rails.root)
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

    expect(rspec.when_files_changed).to eq(%w[app/**/*.rb lib/**/*.rb spec/**/*.rb])
    expect(rspec_focused.when_files_changed).to eq(%w[app/**/*.rb lib/**/*.rb spec/**/*.rb])
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

  it "scopes the website build grader to website and website deploy changes" do
    config = SyrusYml.new(Rails.root.join(".syrus.yml").read).parse
    graph = TargetGraph::Compiler.compile(Rails.root)
    grader = config.grade.steps.find { |step| step.name == "website-build" }

    expect(grader.when_files_changed).to contain_exactly(
      "website/**/*",
      ".github/workflows/deploy-website.yml"
    )
    expect(graph.affected("//:grade/website-build", changed_files: [ "website/src/app/page.tsx" ]).affected).to be(true)
    expect(graph.affected("//:grade/website-build", changed_files: [ ".github/workflows/deploy-website.yml" ]).affected).to be(true)
    expect(graph.affected("//:grade/website-build", changed_files: [ "app/models/job.rb" ]).affected).to be(false)
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
end
