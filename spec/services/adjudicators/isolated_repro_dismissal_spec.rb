require "rails_helper"

RSpec.describe Adjudicators::IsolatedReproDismissal do
  let(:repository) { Factories.repository(isolated_repro_dismissal_enabled: true) }
  let(:job) { Factories.job(repository: repository) }
  let(:workflow) { job.workflows.first }
  let(:sha) { "a" * 40 }
  let(:grader_step) do
    workflow.steps.first.tap { |step| step.update!(details: { "name" => "rspec", "required" => true }) }
  end

  def fake_provider(failed_test_cases:, evidence: {})
    Module.new do
      define_singleton_method(:failed_test_cases) { |run:, grader_name:| failed_test_cases }
      define_singleton_method(:isolated_repro_evidence) { |repository:, suite_name:, name:, sha:| evidence[[ suite_name, name, sha ]] }
    end
  end

  def stub_provider(provider)
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:test_evidence).and_return([ provider ])
  end

  # Sets the known-failing-SHA artifact right before adjudicating -- not in a
  # shared `before` hook. A `before` hook would force `workflow` (and its
  # cached `job`/`repository` association) to materialize ahead of any
  # per-example `repository.update!`, and Rails does not refresh an
  # already-loaded `belongs_to` association just because a different Ruby
  # object representing the same row was updated -- so a test that flips
  # `isolated_repro_dismissal_enabled` after that early materialization would
  # see a stale value. Calling this from inside each example instead keeps
  # `workflow`/`job`/`repository` lazily resolved in the same order the
  # example itself performs its setup.
  def adjudicate(with_sha: true)
    workflow.set_artifact!(GraderConclusionCache::ARTIFACT_HEAD_SHA_KEY, sha) if with_sha
    described_class.adjudicate(problem: Problem[:grader_failure], workflow: workflow, step: [ grader_step ])
  end

  it "declines for a problem that is not a grader failure" do
    expect(described_class.adjudicate(problem: Problem[:timeout], workflow: workflow)).to be_inconclusive
  end

  it "declines when there is no workflow to reason about" do
    expect(described_class.adjudicate(problem: Problem[:grader_failure])).to be_inconclusive
  end

  it "declines when the repository has not opted in" do
    repository.update!(isolated_repro_dismissal_enabled: false)
    stub_provider(fake_provider(
      failed_test_cases: [ { "suite_name" => "S", "name" => "n" } ],
      evidence: { [ "S", "n", sha ] => { reproduced: false, recorded_at: Time.current } }
    ))

    verdict = adjudicate

    expect(verdict).to be_inconclusive
    expect(verdict.reason).to eq("not_enabled")
  end

  it "declines when there is no known failing SHA recorded for the workflow" do
    stub_provider(fake_provider(
      failed_test_cases: [ { "suite_name" => "S", "name" => "n" } ],
      evidence: { [ "S", "n", sha ] => { reproduced: false } }
    ))

    verdict = adjudicate(with_sha: false)

    expect(verdict).to be_inconclusive
    expect(verdict.reason).to eq("no_head_sha")
  end

  it "dismisses a failure whose every failing test has a same-SHA non-reproduction record" do
    stub_provider(fake_provider(
      failed_test_cases: [ { "suite_name" => "spec/foo_spec.rb", "name" => "does the thing" } ],
      evidence: { [ "spec/foo_spec.rb", "does the thing", sha ] => { reproduced: false, recorded_at: Time.current } }
    ))

    verdict = adjudicate

    expect(verdict).to be_dismiss
    expect(verdict.reason).to eq("isolated_repro_did_not_reproduce")
    expect(verdict.evidence[:sha]).to eq(sha)
    expect(verdict.evidence[:tests]).to contain_exactly(
      hash_including(suite_name: "spec/foo_spec.rb", name: "does the thing", reproduced: false)
    )
  end

  it "declines when the recorded evidence is for a different SHA" do
    other_sha = "b" * 40
    stub_provider(fake_provider(
      failed_test_cases: [ { "suite_name" => "spec/foo_spec.rb", "name" => "does the thing" } ],
      evidence: { [ "spec/foo_spec.rb", "does the thing", other_sha ] => { reproduced: false } }
    ))

    verdict = adjudicate

    expect(verdict).to be_inconclusive
    expect(verdict.reason).to eq("no_isolated_repro_evidence")
  end

  it "declines when the isolated repro attempt DID reproduce the failure" do
    stub_provider(fake_provider(
      failed_test_cases: [ { "suite_name" => "spec/foo_spec.rb", "name" => "does the thing" } ],
      evidence: { [ "spec/foo_spec.rb", "does the thing", sha ] => { reproduced: true, recorded_at: Time.current } }
    ))

    verdict = adjudicate

    expect(verdict).to be_inconclusive
    expect(verdict.reason).to eq("not_all_confirmed_non_reproducing")
  end

  it "declines when only some failing tests have a non-reproduction record" do
    stub_provider(fake_provider(
      failed_test_cases: [
        { "suite_name" => "spec/foo_spec.rb", "name" => "flaky one" },
        { "suite_name" => "spec/foo_spec.rb", "name" => "real regression" }
      ],
      evidence: {
        [ "spec/foo_spec.rb", "flaky one", sha ] => { reproduced: false }
      }
    ))

    verdict = adjudicate

    expect(verdict).to be_inconclusive
    expect(verdict.reason).to eq("no_isolated_repro_evidence")
  end

  it "declines when no test_evidence provider is registered" do
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:test_evidence).and_return([])

    verdict = adjudicate

    expect(verdict).to be_inconclusive
    expect(verdict.reason).to eq("no_isolated_repro_evidence")
  end

  it "declines when the grader step recorded no failing test cases" do
    stub_provider(fake_provider(failed_test_cases: []))

    verdict = adjudicate

    expect(verdict).to be_inconclusive
    expect(verdict.reason).to eq("no_isolated_repro_evidence")
  end

  it "derives the failed grader steps from the workflow when step: is not given" do
    grader_step.update!(kind: "grader", state: "failed")
    workflow.set_artifact!(GraderConclusionCache::ARTIFACT_HEAD_SHA_KEY, sha)
    stub_provider(fake_provider(
      failed_test_cases: [ { "suite_name" => "spec/foo_spec.rb", "name" => "does the thing" } ],
      evidence: { [ "spec/foo_spec.rb", "does the thing", sha ] => { reproduced: false } }
    ))

    verdict = described_class.adjudicate(problem: Problem[:grader_failure], workflow: workflow)

    expect(verdict).to be_dismiss
    expect(verdict.reason).to eq("isolated_repro_did_not_reproduce")
  end
end
