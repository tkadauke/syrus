# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Syrus grader configuration" do
  it "gives Rails-booting plugin model namespace checks enough grader headroom" do
    grader = RepoGradePlan.for(Rails.root).graders.find { |entry| entry.name == "plugin-model-namespaces" }

    expect(grader).not_to be_nil
    expect(grader.timeout_minutes).to eq(3)
  end

  it "runs Go CLI tests when CLI or CLI packaging paths change" do
    config = SyrusYml.new(Rails.root.join(".syrus.yml").read).parse

    grader = config.grade.steps.find { |step| step.name == "cli-go-tests" }

    # Enumerating go.work rather than testing `./...` inside cli/: a plugin
    # contributes its CLI commands from its own module, and those tests have to
    # run without anyone remembering to extend this command.
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
end
