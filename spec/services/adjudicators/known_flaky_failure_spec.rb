require "rails_helper"

RSpec.describe Adjudicators::KnownFlakyFailure do
  let(:repository) { Factories.repository(known_flaky_failure_dismissal_enabled: true) }
  let(:job) { Factories.job(repository: repository) }
  let(:workflow) { job.workflows.first }
  let(:grader_step) do
    workflow.steps.first.tap { |step| step.update!(details: { "name" => "rspec", "required" => true, "exit_code" => 1 }) }
  end

  let(:base_sha) { "b" * 40 }

  def fake_provider(failed_test_cases:, scores: {}, signatures: nil, failure_explained: true)
    failed_test_cases = failed_test_cases.map { |test_case| { "failure_message" => "historical failure" }.merge(test_case) }
    signatures ||= failed_test_cases.to_h { |test_case| [ [ test_case["suite_name"], test_case["name"] ], test_case["failure_message"] ] }
    Module.new do
      define_singleton_method(:failed_test_cases) { |run:, grader_name:| failed_test_cases }
      define_singleton_method(:grader_failure_explained_by_tests?) { |**| failure_explained }
      define_singleton_method(:flakiness_score) { |repository:, suite_name:, name:, exclude_workflow: nil| scores[[ suite_name, name ]] }
      define_singleton_method(:historical_failure_signatures) { |repository:, suite_name:, name:, exclude_workflow: nil| Array(signatures[[ suite_name, name ]]) }
    end
  end

  def stub_provider(provider)
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:test_evidence).and_return([ provider ])
  end

  def adjudicate
    allow(WorkflowWorkspace).to receive(:path_for).with(workflow).and_return(Pathname.new(Dir.tmpdir))
    allow_any_instance_of(GitRunner).to receive(:run).with("diff", "--name-only", "#{base_sha}...HEAD", any_args).and_return("")
    described_class.adjudicate(problem: Problem[:grader_failure], workflow: workflow, step: [ grader_step ], base_sha: base_sha)
  end

  it "declines for a problem that is not a grader failure" do
    expect(described_class.adjudicate(problem: Problem[:timeout], workflow: workflow)).to be_inconclusive
  end

  it "declines when there is no workflow to reason about" do
    expect(described_class.adjudicate(problem: Problem[:grader_failure])).to be_inconclusive
  end

  it "declines when the repository has not opted in" do
    repository.update!(known_flaky_failure_dismissal_enabled: false)
    stub_provider(fake_provider(
      failed_test_cases: [ { "suite_name" => "S", "name" => "n" } ],
      scores: { [ "S", "n" ] => { score: 1.0, flaky: true } }
    ))

    verdict = adjudicate

    expect(verdict).to be_inconclusive
    expect(verdict.reason).to eq("not_enabled")
  end

  it "dismisses a failure whose every failing test is confirmed flaky" do
    stub_provider(fake_provider(
      failed_test_cases: [ { "suite_name" => "spec/foo_spec.rb", "name" => "does the thing", "failure_message" => "historical failure" } ],
      scores: { [ "spec/foo_spec.rb", "does the thing" ] => { score: 0.4, failed_count: 4, total_count: 10, flaky: true } }
    ))

    verdict = adjudicate

    expect(verdict).to be_dismiss
    expect(verdict.reason).to eq("known_flaky_failure")
    expect(verdict.evidence[:tests]).to contain_exactly(
      hash_including(suite_name: "spec/foo_spec.rb", name: "does the thing", confirmed_flaky: true)
    )
  end

  it "derives the failed grader steps from the workflow when step: is not given" do
    grader_step.update!(kind: "grader", state: "failed")
    stub_provider(fake_provider(
      failed_test_cases: [ { "suite_name" => "spec/foo_spec.rb", "name" => "does the thing" } ],
      scores: { [ "spec/foo_spec.rb", "does the thing" ] => { score: 0.4, flaky: true } }
    ))

    allow(WorkflowWorkspace).to receive(:path_for).with(workflow).and_return(Pathname.new(Dir.tmpdir))
    allow_any_instance_of(GitRunner).to receive(:run).and_return("")
    verdict = described_class.adjudicate(problem: Problem[:grader_failure], workflow: workflow, base_sha: base_sha)

    expect(verdict).to be_dismiss
    expect(verdict.reason).to eq("known_flaky_failure")
  end

  it "declines when only some failing tests are confirmed flaky" do
    stub_provider(fake_provider(
      failed_test_cases: [
        { "suite_name" => "spec/foo_spec.rb", "name" => "flaky one" },
        { "suite_name" => "spec/foo_spec.rb", "name" => "real regression" }
      ],
      scores: {
        [ "spec/foo_spec.rb", "flaky one" ] => { score: 0.4, flaky: true },
        [ "spec/foo_spec.rb", "real regression" ] => { score: 0.4, flaky: false }
      }
    ))

    verdict = adjudicate

    expect(verdict).to be_inconclusive
    expect(verdict.reason).to eq("not_all_confirmed_flaky")
  end

  it "declines when there is no flakiness history for a failing test" do
    stub_provider(fake_provider(
      failed_test_cases: [ { "suite_name" => "spec/foo_spec.rb", "name" => "brand new" } ],
      scores: {}
    ))

    verdict = adjudicate

    expect(verdict).to be_inconclusive
    expect(verdict.reason).to eq("no_flakiness_history")
  end

  it "declines below the configured minimum score" do
    repository.update!(known_flaky_failure_min_score: 0.5)
    stub_provider(fake_provider(
      failed_test_cases: [ { "suite_name" => "spec/foo_spec.rb", "name" => "barely flaky" } ],
      scores: { [ "spec/foo_spec.rb", "barely flaky" ] => { score: 0.05, flaky: true } }
    ))

    verdict = adjudicate

    expect(verdict).to be_inconclusive
    expect(verdict.reason).to eq("not_all_confirmed_flaky")
  end

  it "declines when recent history is mostly failures" do
    stub_provider(fake_provider(
      failed_test_cases: [ { "suite_name" => "spec/foo_spec.rb", "name" => "currently broken" } ],
      scores: {
        [ "spec/foo_spec.rb", "currently broken" ] => {
          score: 0.75,
          failed_count: 15,
          total_count: 20,
          flaky: true
        }
      }
    ))

    verdict = adjudicate

    expect(verdict).to be_inconclusive
    expect(verdict.reason).to eq("recent_failures_too_frequent")
  end

  it "asks the score provider to exclude the workflow being adjudicated" do
    provider = Module.new do
      class << self
        attr_reader :excluded_workflow

        def failed_test_cases(run:, grader_name:)
          [ { "suite_name" => "spec/foo_spec.rb", "name" => "does the thing" } ]
        end

        def flakiness_score(repository:, suite_name:, name:, exclude_workflow: nil)
          @excluded_workflow = exclude_workflow
          { score: 0.4, failed_count: 4, total_count: 10, flaky: true }
        end

        def grader_failure_explained_by_tests?(**) = true
      end
    end
    stub_provider(provider)

    adjudicate

    expect(provider.excluded_workflow).to eq(workflow)
  end

  it "declines when no test_evidence provider is registered" do
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:test_evidence).and_return([])

    verdict = adjudicate

    expect(verdict).to be_inconclusive
    expect(verdict.reason).to eq("no_flakiness_history")
  end

  it "declines when the grader step recorded no failing test cases" do
    stub_provider(fake_provider(failed_test_cases: []))

    verdict = adjudicate

    expect(verdict).to be_inconclusive
    expect(verdict.reason).to eq("no_flakiness_history")
  end

  it "declines when the PR changed the failing test file" do
    test_case = { "suite_name" => "Foo", "name" => "bar", "file_path" => "spec/foo_spec.rb", "failure_message" => "boom" }
    stub_provider(fake_provider(failed_test_cases: [ test_case ], scores: { [ "Foo", "bar" ] => { score: 0.2, flaky: true } }))
    allow(WorkflowWorkspace).to receive(:path_for).with(workflow).and_return(Pathname.new(Dir.tmpdir))
    allow_any_instance_of(GitRunner).to receive(:run).and_return("spec/foo_spec.rb\n")

    verdict = described_class.adjudicate(
      problem: Problem[:grader_failure], workflow: workflow, step: [ grader_step ], base_sha: base_sha
    )
    expect(verdict.reason).to eq("changed_failing_test")
  end

  it "declines when the current failure signature differs from history" do
    test_case = { "suite_name" => "Foo", "name" => "bar", "failure_message" => "new regression" }
    stub_provider(fake_provider(
      failed_test_cases: [ test_case ], scores: { [ "Foo", "bar" ] => { score: 0.2, flaky: true } },
      signatures: { [ "Foo", "bar" ] => "old flaky failure" }
    ))

    expect(adjudicate.reason).to eq("no_flakiness_history")
  end

  it "declines when a mixed non-test cause means the parsed flaky case does not explain the grader exit" do
    test_case = { "suite_name" => "Foo", "name" => "bar", "failure_message" => "known failure" }
    stub_provider(fake_provider(
      failed_test_cases: [ test_case ], scores: { [ "Foo", "bar" ] => { score: 0.2, flaky: true } },
      failure_explained: false
    ))

    expect(adjudicate.reason).to eq("no_flakiness_history")
  end
end
