require "rails_helper"

RSpec.describe Adjudicators::KnownFlakyFailure do
  let(:repository) { Factories.repository(known_flaky_failure_dismissal_enabled: true) }
  let(:job) { Factories.job(repository: repository) }
  let(:workflow) { job.workflows.first }
  let(:grader_step) do
    workflow.steps.first.tap { |step| step.update!(details: { "name" => "rspec", "required" => true }) }
  end

  def fake_provider(failed_test_cases:, scores: {})
    Module.new do
      define_singleton_method(:failed_test_cases) { |run:, grader_name:| failed_test_cases }
      define_singleton_method(:flakiness_score) { |repository:, suite_name:, name:| scores[[ suite_name, name ]] }
    end
  end

  def stub_provider(provider)
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:test_evidence).and_return([ provider ])
  end

  def adjudicate
    described_class.adjudicate(problem: Problem[:grader_failure], workflow: workflow, step: [ grader_step ])
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
      failed_test_cases: [ { "suite_name" => "spec/foo_spec.rb", "name" => "does the thing" } ],
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

    verdict = described_class.adjudicate(problem: Problem[:grader_failure], workflow: workflow)

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
        [ "spec/foo_spec.rb", "real regression" ] => { score: 1.0, flaky: false }
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
      failed_test_cases: [ { "suite_name" => "spec/foo_spec.rb", "name" => "mostly broken" } ],
      scores: {
        [ "spec/foo_spec.rb", "mostly broken" ] => {
          score: 0.75,
          failed_count: 15,
          total_count: 20,
          flaky: true
        }
      }
    ))

    verdict = adjudicate

    expect(verdict).to be_inconclusive
    expect(verdict.reason).to eq("too_consistently_failing")
  end

  it "passes the current workflow to providers that can exclude it from history" do
    observed_workflow = nil
    provider = Module.new do
      define_singleton_method(:failed_test_cases) do |run:, grader_name:|
        [ { "suite_name" => "spec/foo_spec.rb", "name" => "self inflated" } ]
      end
      define_singleton_method(:flakiness_score) do |repository:, suite_name:, name:, workflow: nil|
        observed_workflow = workflow
        { score: 0.4, failed_count: 2, total_count: 5, flaky: true }
      end
    end
    stub_provider(provider)

    verdict = adjudicate

    expect(verdict).to be_dismiss
    expect(observed_workflow).to eq(workflow)
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
end
