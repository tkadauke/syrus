require "rails_helper"

RSpec.describe GraderConclusionCache do
  def grader(name:, command: "bin/check", required: true, timeout_minutes: 10, when_files_changed: nil)
    RepoGradePlan::Grader.new(
      name: name,
      command: command,
      fast_command: nil,
      description: nil,
      required: required,
      timeout_minutes: timeout_minutes,
      when_files_changed: when_files_changed,
      junit_output: nil,
      metadata: {}
    )
  end

  it "fingerprints when_files_changed because those globs affect grader selection" do
    first = RepoGradePlan::Result.new(
      graders: [ grader(name: "site", when_files_changed: [ "website/**" ]) ],
      source: ".syrus.yml",
      note: nil,
      max_iterations: 1
    )
    second = first.with(
      graders: [ grader(name: "site", when_files_changed: [ "docs/**" ]) ]
    )

    expect(described_class.fingerprint_for_plan(first)).not_to eq(described_class.fingerprint_for_plan(second))
  end

  it "normalizes when_files_changed order in fingerprints" do
    first = RepoGradePlan::Result.new(
      graders: [ grader(name: "site", when_files_changed: [ "website/**", "docs/**" ]) ],
      source: ".syrus.yml",
      note: nil,
      max_iterations: 1
    )
    second = first.with(
      graders: [ grader(name: "site", when_files_changed: [ "docs/**", "website/**" ]) ]
    )

    expect(described_class.fingerprint_for_plan(first)).to eq(described_class.fingerprint_for_plan(second))
  end
end
