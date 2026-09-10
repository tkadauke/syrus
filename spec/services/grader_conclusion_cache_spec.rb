require "rails_helper"

RSpec.describe GraderConclusionCache do
  def grader(name:, command: "bin/check", required: true, timeout_minutes: 10, when_files_changed: nil)
    RepoGradePlan::Grader.new(
      name: name,
      command: command,
      phases: %w[review landing ci],
      description: nil,
      required: required,
      timeout_minutes: timeout_minutes,
      when_files_changed: when_files_changed,
      junit_output: nil,
      failures: "strict",
      deps: [],
      metadata: {}
    )
  end

  it "fingerprints when_files_changed because those globs affect grader selection" do
    first = RepoGradePlan::Result.new(
      graders: [ grader(name: "site", when_files_changed: [ "website/**" ]) ],
      source: ".syrus.yml",
      note: nil,
      max_iterations: 1,
      rerun_only_failed: false
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
      max_iterations: 1,
      rerun_only_failed: false
    )
    second = first.with(
      graders: [ grader(name: "site", when_files_changed: [ "docs/**", "website/**" ]) ]
    )

    expect(described_class.fingerprint_for_plan(first)).to eq(described_class.fingerprint_for_plan(second))
  end

  it "fingerprints dependency refs because they affect grader selection" do
    first = RepoGradePlan::Result.new(
      graders: [ grader(name: "site").with(deps: [ ":frontend" ]) ],
      source: ".syrus.yml",
      note: nil,
      max_iterations: 1,
      rerun_only_failed: false
    )
    second = first.with(
      graders: [ grader(name: "site").with(deps: [ ":backend" ]) ]
    )

    expect(described_class.fingerprint_for_plan(first)).not_to eq(described_class.fingerprint_for_plan(second))
  end

  it "fingerprints execution config that changes grader semantics" do
    first = RepoGradePlan::Result.new(
      graders: [
        grader(name: "site", command: "npm test", required: true, timeout_minutes: 10)
          .with(phases: %w[review landing], failures: "strict", junit_output: "tmp/site.xml")
      ],
      source: ".syrus.yml",
      note: nil,
      max_iterations: 1,
      rerun_only_failed: false
    )
    second = first.with(
      graders: [
        grader(name: "site", command: "npm test", required: false, timeout_minutes: 20)
          .with(phases: %w[landing], failures: "lenient", junit_output: "tmp/changed.xml")
      ]
    )

    expect(described_class.fingerprint_for_plan(first)).not_to eq(described_class.fingerprint_for_plan(second))
  end

  it "reads grader status from the latest run projection when step state is stale" do
    user = Factories.user
    repository = Factories.repository(user: user)
    job = Factories.job_record(user: user, repository: repository)
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
    step = Step.create!(workflow: workflow, kind: "grader", position: 0, state: "running")
    Run.create!(job: job, step: step, trigger_kind: "initial", state: "succeeded")

    expect(described_class.status_for_step(step)).to eq("passed")
  end
end
