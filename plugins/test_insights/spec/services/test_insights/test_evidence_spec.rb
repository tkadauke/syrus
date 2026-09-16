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
end
