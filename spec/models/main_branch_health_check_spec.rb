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
