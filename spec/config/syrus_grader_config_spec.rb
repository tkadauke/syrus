# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Syrus grader configuration" do
  it "gives Rails-booting plugin model namespace checks enough grader headroom" do
    grader = RepoGradePlan.for(Rails.root).graders.find { |entry| entry.name == "plugin-model-namespaces" }

    expect(grader).not_to be_nil
    expect(grader.timeout_minutes).to eq(3)
  end

  it "keeps only cross-project CLI workspace checks in the root config" do
    config = SyrusYml.new(Rails.root.join(".syrus.yml").read).parse

    grader = config.grade.steps.find { |step| step.name == "cli-go-workspace-backstop" }

    # The core CLI module is owned by cli/.syrus.yml. This root grader remains
    # only for Go workspace changes that cross project boundaries.
    expect(grader).to have_attributes(
      run: %(mise exec go@1.26.5 -- sh -c 'go test $(go list -m -f "{{.Dir}}/...")'),
      phases: %w[review landing ci],
      required: true,
      timeout_minutes: 5
    )
    expect(grader.when_files_changed).to include(
      "go.work",
      "plugins/*/cli/**/*.go",
      "plugins/*/cli/go.mod",
      "bin/release-cli",
      "desktop/scripts/stage-cli.mjs"
    )
    expect(grader.when_files_changed).not_to include(
      "cli/**/*.go",
      "cli/go.mod",
      "cli/go.sum",
      "cli/Makefile"
    )
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

  it "selects the CLI target, not the root workspace backstop, for core CLI changes" do
    graph = TargetGraph::Compiler.compile(Rails.root)

    cli_prepare = graph.target("//cli:prepare")
    cli_tests = graph.affected("//cli:grade/go-tests", changed_files: [ "cli/cmd/jobs.go" ])
    root_backstop = graph.affected("//:grade/cli-go-workspace-backstop", changed_files: [ "cli/cmd/jobs.go" ])
    plugin_cli = graph.affected("//:grade/cli-go-workspace-backstop", changed_files: [ "plugins/example/cli/cmd/example.go" ])

    expect(cli_prepare.command).to eq("mise exec go@1.26.5 -- go mod download")
    expect(cli_tests.affected).to be(true)
    expect(root_backstop.affected).to be(false)
    expect(plugin_cli.affected).to be(true)
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
