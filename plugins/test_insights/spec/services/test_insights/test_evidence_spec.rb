require "rails_helper"

RSpec.describe TestInsights::TestEvidence do
  let(:job)  { Factories.job }
  let(:run)  { job.initial_run }
  let(:repo) { job.repository }
  let(:sha)  { "c" * 40 }

  describe ".record_isolated_repro! / .isolated_repro_evidence" do
    it "records a repro attempt and returns it as evidence for the exact (suite_name, name, sha)" do
      described_class.record_isolated_repro!(
        repository: repo,
        job: job,
        workflow: run.workflow,
        run: run,
        grader_name: "rspec",
        suite_name: "spec/foo_spec.rb",
        name: "does the thing",
        sha: sha,
        reproduced: false,
        command: "bundle exec rspec spec/foo_spec.rb -e 'does the thing'",
        output: "1 example, 0 failures",
        exit_status: 0
      )

      evidence = described_class.isolated_repro_evidence(
        repository: repo, suite_name: "spec/foo_spec.rb", name: "does the thing", sha: sha
      )

      expect(evidence).to include(reproduced: false, grader_name: "rspec")
      expect(evidence[:command]).to eq("bundle exec rspec spec/foo_spec.rb -e 'does the thing'")
    end

    it "stores the record in its own table, never TestInsights::TestCase" do
      expect {
        described_class.record_isolated_repro!(
          repository: repo, grader_name: "rspec", suite_name: "spec/foo_spec.rb", name: "does the thing",
          sha: sha, reproduced: false, command: "bundle exec rspec", output: "ok"
        )
      }.to change(TestInsights::IsolatedReproAttempt, :count).by(1)

      expect(TestInsights::TestCase.count).to eq(0)
    end

    it "never feeds TestCase.flakiness_score's statistical pool" do
      described_class.record_isolated_repro!(
        repository: repo, grader_name: "rspec", suite_name: "spec/foo_spec.rb", name: "does the thing",
        sha: sha, reproduced: false, command: "bundle exec rspec", output: "ok"
      )

      expect(TestInsights::TestCase.flakiness_score(repository: repo, suite_name: "spec/foo_spec.rb", name: "does the thing")).to be_nil
    end

    it "returns nil evidence for a different SHA than the one recorded" do
      described_class.record_isolated_repro!(
        repository: repo, grader_name: "rspec", suite_name: "spec/foo_spec.rb", name: "does the thing",
        sha: sha, reproduced: false, command: "bundle exec rspec", output: "ok"
      )

      evidence = described_class.isolated_repro_evidence(
        repository: repo, suite_name: "spec/foo_spec.rb", name: "does the thing", sha: "d" * 40
      )

      expect(evidence).to be_nil
    end

    it "returns nil evidence when nothing has been recorded" do
      evidence = described_class.isolated_repro_evidence(
        repository: repo, suite_name: "spec/nope_spec.rb", name: "never ran", sha: sha
      )

      expect(evidence).to be_nil
    end

    it "returns the most recent record when a test was reproed more than once" do
      described_class.record_isolated_repro!(
        repository: repo, grader_name: "rspec", suite_name: "spec/foo_spec.rb", name: "does the thing",
        sha: sha, reproduced: false, command: "first attempt", output: "ok"
      )
      described_class.record_isolated_repro!(
        repository: repo, grader_name: "rspec", suite_name: "spec/foo_spec.rb", name: "does the thing",
        sha: sha, reproduced: true, command: "second attempt", output: "reproduced this time"
      )

      evidence = described_class.isolated_repro_evidence(
        repository: repo, suite_name: "spec/foo_spec.rb", name: "does the thing", sha: sha
      )

      expect(evidence).to include(reproduced: true, command: "second attempt")
    end
  end

  describe ".failed_test_cases" do
    def test_run
      @test_run ||= TestInsights::TestRun.create!(
        run: run, repository: repo, grader_name: "rspec",
        total_count: 0, passed_count: 0, failed_count: 0, skipped_count: 0, error_count: 0
      )
    end

    def create_test_case(status:, name:, suite_name: "spec/foo_spec.rb", failure_message: nil)
      TestInsights::TestCase.create!(
        test_run: test_run, repository: repo, name: name, suite_name: suite_name,
        status: status, failure_message: failure_message
      )
    end

    it "returns only failed/error cases for the given run and grader, with a short failure_message snippet" do
      create_test_case(status: "passed", name: "passes")
      create_test_case(status: "failed", name: "fails", failure_message: "expected true\n  got false\nbacktrace line")
      create_test_case(status: "error", name: "errors", failure_message: "boom")

      cases = described_class.failed_test_cases(run: run, grader_name: "rspec")

      expect(cases.map { |c| c["name"] }).to contain_exactly("fails", "errors")
      failing = cases.find { |c| c["name"] == "fails" }
      expect(failing["failure_message"]).to eq("expected true")
      expect(failing["suite_name"]).to eq("spec/foo_spec.rb")
      expect(failing["identity"]).to eq([ "spec/foo_spec.rb", "fails" ].join(0.chr))
    end

    it "returns nil failure_message when the underlying test case has none" do
      create_test_case(status: "failed", name: "fails", failure_message: nil)

      cases = described_class.failed_test_cases(run: run, grader_name: "rspec")

      expect(cases.sole["failure_message"]).to be_nil
    end

    it "truncates a long failure message to the configured byte budget" do
      long_message = "x" * 1000
      create_test_case(status: "failed", name: "fails", failure_message: long_message)

      cases = described_class.failed_test_cases(run: run, grader_name: "rspec")

      expect(cases.sole["failure_message"].bytesize).to eq(TestInsights::TestEvidence::FAILURE_MESSAGE_SNIPPET_BYTES)
    end

    it "returns an empty array for a run with no ingested test data" do
      expect(described_class.failed_test_cases(run: run, grader_name: "rspec")).to eq([])
    end

    it "returns an empty array when the run is nil" do
      expect(described_class.failed_test_cases(run: nil, grader_name: "rspec")).to eq([])
    end
  end
end
