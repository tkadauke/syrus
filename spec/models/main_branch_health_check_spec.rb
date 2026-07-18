require "rails_helper"

RSpec.describe MainBranchHealthCheck do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  describe "validations" do
    it "is valid with all required attributes" do
      check = MainBranchHealthCheck.new(
        repository: repository,
        sha: "abc123",
        checked_at: Time.current,
        ci_health: "healthy",
        grader_health: "unknown",
        source: "ci_poll"
      )
      expect(check).to be_valid
    end

    it "requires sha" do
      check = MainBranchHealthCheck.new(repository: repository, checked_at: Time.current, source: "ci_poll")
      expect(check).not_to be_valid
      expect(check.errors[:sha]).to be_present
    end

    it "requires checked_at" do
      check = MainBranchHealthCheck.new(repository: repository, sha: "abc123", source: "ci_poll")
      expect(check).not_to be_valid
      expect(check.errors[:checked_at]).to be_present
    end

    it "requires source" do
      check = MainBranchHealthCheck.new(repository: repository, sha: "abc123", checked_at: Time.current)
      expect(check).not_to be_valid
      expect(check.errors[:source]).to be_present
    end

    it "rejects unknown source values" do
      check = MainBranchHealthCheck.new(
        repository: repository, sha: "abc123", checked_at: Time.current, source: "manual"
      )
      expect(check).not_to be_valid
      expect(check.errors[:source]).to be_present
    end

    it "accepts ci_poll as a valid source" do
      check = MainBranchHealthCheck.new(
        repository: repository, sha: "abc123", checked_at: Time.current, source: "ci_poll"
      )
      expect(check).to be_valid
    end

    it "accepts grader_workflow as a valid source" do
      check = MainBranchHealthCheck.new(
        repository: repository, sha: "abc123", checked_at: Time.current, source: "grader_workflow"
      )
      expect(check).to be_valid
    end

    it "accepts concern_quorum as a valid source" do
      check = MainBranchHealthCheck.new(
        repository: repository, sha: "abc123", checked_at: Time.current, source: "concern_quorum"
      )
      expect(check).to be_valid
    end
  end

  describe ".recent scope" do
    it "orders checks by checked_at descending" do
      old = MainBranchHealthCheck.create!(
        repository: repository, sha: "old", checked_at: 2.hours.ago,
        ci_health: "unknown", grader_health: "unknown", source: "ci_poll"
      )
      newer = MainBranchHealthCheck.create!(
        repository: repository, sha: "new", checked_at: 1.hour.ago,
        ci_health: "healthy", grader_health: "unknown", source: "ci_poll"
      )
      expect(MainBranchHealthCheck.recent.to_a).to eq([newer, old])
    end
  end

  describe ".pruneable scope" do
    it "includes checks older than RETAIN_AFTER" do
      old = MainBranchHealthCheck.create!(
        repository: repository, sha: "old", checked_at: 8.days.ago,
        ci_health: "unknown", grader_health: "unknown", source: "ci_poll"
      )
      MainBranchHealthCheck.create!(
        repository: repository, sha: "new", checked_at: 1.hour.ago,
        ci_health: "healthy", grader_health: "unknown", source: "ci_poll"
      )
      expect(MainBranchHealthCheck.pruneable).to contain_exactly(old)
    end
  end

  describe ".record_ci_poll" do
    it "creates a record with the given ci_health and snapshot of grader_health" do
      repository.update!(grader_health: "healthy")
      check = MainBranchHealthCheck.record_ci_poll(
        repository: repository, sha: "deadbeef", ci_health: "broken",
        ci_failed_checks: [{ name: "tests", url: "https://github.com/check/1" }]
      )

      expect(check).to be_persisted
      expect(check.source).to eq("ci_poll")
      expect(check.sha).to eq("deadbeef")
      expect(check.ci_health).to eq("broken")
      expect(check.grader_health).to eq("healthy")
      expect(check.ci_failed_checks).to eq([{ "name" => "tests", "url" => "https://github.com/check/1" }])
      expect(check.grader_failed_names).to be_nil
    end

    it "records nil ci_failed_checks when not provided" do
      check = MainBranchHealthCheck.record_ci_poll(
        repository: repository, sha: "abc", ci_health: "healthy"
      )
      expect(check.ci_failed_checks).to be_nil
    end

    it "updates the existing record when called again for the same SHA" do
      first = MainBranchHealthCheck.record_ci_poll(
        repository: repository,
        sha: "abc",
        ci_health: "broken",
        ci_failed_checks: [{ name: "RSpec", url: "https://github.com/check/42" }]
      )

      updated = nil
      expect {
        updated = MainBranchHealthCheck.record_ci_poll(
          repository: repository,
          sha: "abc",
          ci_health: "broken",
          ci_failed_checks: [{ name: "RSpec", url: "https://github.com/check/42" }]
        )
      }.not_to change(MainBranchHealthCheck, :count)
      expect(updated).to eq(first)
    end

    it "updates ci fields in place when CI failures change" do
      MainBranchHealthCheck.record_ci_poll(
        repository: repository,
        sha: "abc",
        ci_health: "broken",
        ci_failed_checks: [{ name: "RSpec" }]
      )

      updated = nil
      expect {
        updated = MainBranchHealthCheck.record_ci_poll(
          repository: repository,
          sha: "abc",
          ci_health: "broken",
          ci_failed_checks: [{ name: "React" }]
        )
      }.not_to change(MainBranchHealthCheck, :count)
      expect(updated.ci_failed_checks).to eq([{ "name" => "React" }])
    end

    it "merges ci data onto an existing grader_workflow row for the same SHA" do
      repository.update!(ci_health: "unknown", grader_health: "unknown")
      grader_row = MainBranchHealthCheck.record_grader_workflow(
        repository: repository, sha: "cafe", grader_health: "healthy"
      )

      merged = nil
      expect {
        merged = MainBranchHealthCheck.record_ci_poll(
          repository: repository, sha: "cafe", ci_health: "broken",
          ci_failed_checks: [{ name: "tests" }]
        )
      }.not_to change(MainBranchHealthCheck, :count)

      expect(merged).to eq(grader_row)
      expect(merged.source).to eq("grader_workflow")
      expect(merged.ci_health).to eq("broken")
      expect(merged.ci_failed_checks).to eq([{ "name" => "tests" }])
      expect(merged.grader_health).to eq("healthy")
    end

    it "creates a separate row for a different SHA" do
      MainBranchHealthCheck.record_ci_poll(repository: repository, sha: "abc", ci_health: "healthy")

      expect {
        MainBranchHealthCheck.record_ci_poll(repository: repository, sha: "def", ci_health: "broken")
      }.to change(MainBranchHealthCheck, :count).by(1)
    end

    it "does not merge onto concern_quorum rows" do
      MainBranchHealthCheck.record_concern_quorum(repository: repository, sha: "abc")

      expect {
        MainBranchHealthCheck.record_ci_poll(repository: repository, sha: "abc", ci_health: "healthy")
      }.to change(MainBranchHealthCheck, :count).by(1)
    end
  end

  describe ".record_grader_workflow" do
    it "creates a record with the given grader_health and snapshot of ci_health" do
      repository.update!(ci_health: "broken")
      check = MainBranchHealthCheck.record_grader_workflow(
        repository: repository, sha: "cafebabe", grader_health: "broken",
        grader_failed_names: ["rubocop", "rspec"]
      )

      expect(check).to be_persisted
      expect(check.source).to eq("grader_workflow")
      expect(check.sha).to eq("cafebabe")
      expect(check.grader_health).to eq("broken")
      expect(check.ci_health).to eq("broken")
      expect(check.grader_failed_names).to eq(["rubocop", "rspec"])
      expect(check.ci_failed_checks).to be_nil
    end

    it "records nil grader_failed_names when not provided" do
      check = MainBranchHealthCheck.record_grader_workflow(
        repository: repository, sha: "abc", grader_health: "healthy"
      )
      expect(check.grader_failed_names).to be_nil
    end

    it "stores the workflow association when provided" do
      workflow = Factories.job(repository: repository).workflows.first
      check = MainBranchHealthCheck.record_grader_workflow(
        repository: repository, sha: "abc", grader_health: "healthy", workflow: workflow
      )
      expect(check.workflow).to eq(workflow)
    end

    it "stores nil workflow when not provided" do
      check = MainBranchHealthCheck.record_grader_workflow(
        repository: repository, sha: "abc", grader_health: "healthy"
      )
      expect(check.workflow).to be_nil
    end

    it "updates the existing record when called again for the same SHA" do
      workflow = Factories.job(repository: repository).workflows.first
      first = MainBranchHealthCheck.record_grader_workflow(
        repository: repository,
        workflow: workflow,
        sha: "abc",
        grader_health: "broken",
        grader_failed_names: [ "rspec" ]
      )

      updated = nil
      expect {
        updated = MainBranchHealthCheck.record_grader_workflow(
          repository: repository,
          workflow: workflow,
          sha: "abc",
          grader_health: "broken",
          grader_failed_names: [ "rspec" ]
        )
      }.not_to change(MainBranchHealthCheck, :count)
      expect(updated).to eq(first)
    end

    it "updates grader fields in place when a different workflow runs for the same SHA" do
      first_workflow = Factories.job(repository: repository).workflows.first
      second_workflow = Factories.job(repository: repository).workflows.first
      MainBranchHealthCheck.record_grader_workflow(
        repository: repository,
        workflow: first_workflow,
        sha: "abc",
        grader_health: "broken",
        grader_failed_names: [ "rspec" ]
      )

      updated = nil
      expect {
        updated = MainBranchHealthCheck.record_grader_workflow(
          repository: repository,
          workflow: second_workflow,
          sha: "abc",
          grader_health: "healthy",
          grader_failed_names: nil
        )
      }.not_to change(MainBranchHealthCheck, :count)
      expect(updated.workflow).to eq(second_workflow)
      expect(updated.grader_health).to eq("healthy")
    end

    it "merges grader data onto an existing ci_poll row for the same SHA" do
      repository.update!(ci_health: "unknown", grader_health: "unknown")
      ci_row = MainBranchHealthCheck.record_ci_poll(
        repository: repository, sha: "dead", ci_health: "broken",
        ci_failed_checks: [{ name: "tests" }]
      )

      merged = nil
      expect {
        merged = MainBranchHealthCheck.record_grader_workflow(
          repository: repository, sha: "dead", grader_health: "healthy"
        )
      }.not_to change(MainBranchHealthCheck, :count)

      expect(merged).to eq(ci_row)
      expect(merged.source).to eq("ci_poll")
      expect(merged.grader_health).to eq("healthy")
      expect(merged.ci_health).to eq("broken")
      expect(merged.ci_failed_checks).to eq([{ "name" => "tests" }])
    end

    it "does not merge onto concern_quorum rows" do
      MainBranchHealthCheck.record_concern_quorum(repository: repository, sha: "abc")

      expect {
        MainBranchHealthCheck.record_grader_workflow(
          repository: repository, sha: "abc", grader_health: "healthy"
        )
      }.to change(MainBranchHealthCheck, :count).by(1)
    end
  end

  describe "cross-source deduplication" do
    it "produces one row when ci_poll arrives before grader_workflow" do
      repository.update!(ci_health: "unknown", grader_health: "unknown")

      MainBranchHealthCheck.record_ci_poll(
        repository: repository, sha: "abcdef", ci_health: "broken",
        ci_failed_checks: [{ name: "rspec" }]
      )
      MainBranchHealthCheck.record_grader_workflow(
        repository: repository, sha: "abcdef", grader_health: "broken",
        grader_failed_names: ["rubocop"]
      )

      checks = MainBranchHealthCheck.where(repository: repository, sha: "abcdef")
      expect(checks.count).to eq(1)
      row = checks.first
      expect(row.ci_health).to eq("broken")
      expect(row.grader_health).to eq("broken")
      expect(row.ci_failed_checks).to eq([{ "name" => "rspec" }])
      expect(row.grader_failed_names).to eq(["rubocop"])
    end

    it "produces one row when grader_workflow arrives before ci_poll" do
      repository.update!(ci_health: "unknown", grader_health: "unknown")

      MainBranchHealthCheck.record_grader_workflow(
        repository: repository, sha: "fedcba", grader_health: "healthy"
      )
      MainBranchHealthCheck.record_ci_poll(
        repository: repository, sha: "fedcba", ci_health: "healthy"
      )

      checks = MainBranchHealthCheck.where(repository: repository, sha: "fedcba")
      expect(checks.count).to eq(1)
      row = checks.first
      expect(row.ci_health).to eq("healthy")
      expect(row.grader_health).to eq("healthy")
    end

    it "creates a separate row for a different SHA" do
      MainBranchHealthCheck.record_ci_poll(repository: repository, sha: "sha1", ci_health: "healthy")
      MainBranchHealthCheck.record_grader_workflow(repository: repository, sha: "sha1", grader_health: "healthy")

      expect {
        MainBranchHealthCheck.record_ci_poll(repository: repository, sha: "sha2", ci_health: "broken")
      }.to change(MainBranchHealthCheck, :count).by(1)

      expect(MainBranchHealthCheck.where(repository: repository).count).to eq(2)
    end
  end

  describe ".record_concern_quorum" do
    it "creates a broken grader record with the current ci_health" do
      repository.update!(ci_health: "healthy")

      check = MainBranchHealthCheck.record_concern_quorum(
        repository: repository,
        sha: "deadbeef",
        grader_failed_names: [ "rspec", "react-tests" ]
      )

      expect(check).to be_persisted
      expect(check.source).to eq("concern_quorum")
      expect(check.sha).to eq("deadbeef")
      expect(check.ci_health).to eq("healthy")
      expect(check.grader_health).to eq("broken")
      expect(check.grader_failed_names).to eq([ "rspec", "react-tests" ])
      expect(check.ci_failed_checks).to be_nil
    end
  end

  describe ".conclusive_grader_result_exists?" do
    it "returns true for a healthy grader result on the same repository and SHA" do
      described_class.record_grader_workflow(repository: repository, sha: "abc", grader_health: "healthy")

      expect(described_class.conclusive_grader_result_exists?(repository: repository, sha: "abc")).to be(true)
    end

    it "returns true for a broken grader result on the same repository and SHA" do
      described_class.record_grader_workflow(repository: repository, sha: "abc", grader_health: "broken")

      expect(described_class.conclusive_grader_result_exists?(repository: repository, sha: "abc")).to be(true)
    end

    it "returns false for an unknown interrupted grader result" do
      described_class.record_grader_workflow(repository: repository, sha: "abc", grader_health: "unknown")

      expect(described_class.conclusive_grader_result_exists?(repository: repository, sha: "abc")).to be(false)
    end

    it "returns false for an inconclusive grader result" do
      described_class.record_grader_workflow(repository: repository, sha: "abc", grader_health: "inconclusive")

      expect(described_class.conclusive_grader_result_exists?(repository: repository, sha: "abc")).to be(false)
    end

    it "does not match another SHA" do
      described_class.record_grader_workflow(repository: repository, sha: "abc", grader_health: "healthy")

      expect(described_class.conclusive_grader_result_exists?(repository: repository, sha: "def")).to be(false)
    end

    it "returns true on a merged row created by ci_poll then grader_workflow" do
      described_class.record_ci_poll(repository: repository, sha: "abc", ci_health: "broken")
      described_class.record_grader_workflow(repository: repository, sha: "abc", grader_health: "healthy")

      expect(described_class.conclusive_grader_result_exists?(repository: repository, sha: "abc")).to be(true)
    end
  end

  describe ".settled_ci_result_exists?" do
    it "returns true for a healthy ci result" do
      described_class.record_ci_poll(repository: repository, sha: "abc", ci_health: "healthy")

      expect(described_class.settled_ci_result_exists?(repository: repository, sha: "abc")).to be(true)
    end

    it "returns true for a broken ci result" do
      described_class.record_ci_poll(repository: repository, sha: "abc", ci_health: "broken")

      expect(described_class.settled_ci_result_exists?(repository: repository, sha: "abc")).to be(true)
    end

    it "returns true for a not_configured ci result" do
      described_class.record_ci_poll(repository: repository, sha: "abc", ci_health: "not_configured")

      expect(described_class.settled_ci_result_exists?(repository: repository, sha: "abc")).to be(true)
    end

    it "returns false when ci_health is unknown" do
      described_class.record_ci_poll(repository: repository, sha: "abc", ci_health: "unknown")

      expect(described_class.settled_ci_result_exists?(repository: repository, sha: "abc")).to be(false)
    end

    it "does not match another SHA" do
      described_class.record_ci_poll(repository: repository, sha: "abc", ci_health: "healthy")

      expect(described_class.settled_ci_result_exists?(repository: repository, sha: "def")).to be(false)
    end

    it "returns true on a merged row created by grader_workflow then ci_poll" do
      described_class.record_grader_workflow(repository: repository, sha: "abc", grader_health: "healthy")
      described_class.record_ci_poll(repository: repository, sha: "abc", ci_health: "broken")

      expect(described_class.settled_ci_result_exists?(repository: repository, sha: "abc")).to be(true)
    end
  end

  describe ".settled_grader_result_exists?" do
    it "returns true for a healthy grader result" do
      described_class.record_grader_workflow(repository: repository, sha: "abc", grader_health: "healthy")

      expect(described_class.settled_grader_result_exists?(repository: repository, sha: "abc")).to be(true)
    end

    it "returns true for a broken grader result" do
      described_class.record_grader_workflow(repository: repository, sha: "abc", grader_health: "broken")

      expect(described_class.settled_grader_result_exists?(repository: repository, sha: "abc")).to be(true)
    end

    it "returns true for an inconclusive grader result" do
      described_class.record_grader_workflow(repository: repository, sha: "abc", grader_health: "inconclusive")

      expect(described_class.settled_grader_result_exists?(repository: repository, sha: "abc")).to be(true)
    end

    it "returns false when grader_health is unknown" do
      described_class.record_grader_workflow(repository: repository, sha: "abc", grader_health: "unknown")

      expect(described_class.settled_grader_result_exists?(repository: repository, sha: "abc")).to be(false)
    end

    it "does not match another SHA" do
      described_class.record_grader_workflow(repository: repository, sha: "abc", grader_health: "healthy")

      expect(described_class.settled_grader_result_exists?(repository: repository, sha: "def")).to be(false)
    end

    it "returns true on a merged row created by ci_poll then grader_workflow" do
      described_class.record_ci_poll(repository: repository, sha: "abc", ci_health: "broken")
      described_class.record_grader_workflow(repository: repository, sha: "abc", grader_health: "broken")

      expect(described_class.settled_grader_result_exists?(repository: repository, sha: "abc")).to be(true)
    end
  end

  describe "association" do
    it "is destroyed when its repository is destroyed" do
      MainBranchHealthCheck.record_ci_poll(repository: repository, sha: "xyz", ci_health: "unknown")
      id = MainBranchHealthCheck.last.id
      repository.destroy!
      expect(MainBranchHealthCheck.find_by(id: id)).to be_nil
    end
  end
end
