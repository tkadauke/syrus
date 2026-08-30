require "rails_helper"

RSpec.describe "Syrus grader config" do
  it "runs Go CLI tests when CLI or CLI packaging paths change" do
    config = SyrusYml.new(Rails.root.join(".syrus.yml").read).parse

    grader = config.grade.steps.find { |step| step.name == "cli-go-tests" }

    expect(grader).to have_attributes(
      run: "cd cli && mise exec go@1.26.5 -- go test ./...",
      phases: %w[review landing ci],
      required: true,
      timeout_minutes: 5
    )
    expect(grader.when_files_changed).to include(
      "cli/**/*.go",
      "cli/go.mod",
      "cli/go.sum",
      "cli/Makefile",
      "bin/release-cli",
      "desktop/scripts/stage-cli.mjs"
    )
  end
end
