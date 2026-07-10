require "rails_helper"

RSpec.describe Repository, "#main_health" do
  let(:repo) { Factories.repository }

  it "is unknown when both ci_health and grader_health are unknown" do
    expect(repo.main_health).to eq("unknown")
  end

  it "is unknown when ci_health is healthy but grader_health is unknown" do
    repo.update!(ci_health: "healthy")
    expect(repo.main_health).to eq("unknown")
  end

  it "is unknown when grader_health is healthy but ci_health is unknown" do
    repo.update!(grader_health: "healthy")
    expect(repo.main_health).to eq("unknown")
  end

  it "is healthy when both ci_health and grader_health are healthy" do
    repo.update!(ci_health: "healthy", grader_health: "healthy")
    expect(repo.main_health).to eq("healthy")
  end

  it "is broken when ci_health is broken regardless of grader_health" do
    repo.update!(ci_health: "broken", grader_health: "unknown")
    expect(repo.main_health).to eq("broken")
  end

  it "is broken when grader_health is broken regardless of ci_health" do
    repo.update!(ci_health: "healthy", grader_health: "broken")
    expect(repo.main_health).to eq("broken")
  end

  it "is broken when both are broken" do
    repo.update!(ci_health: "broken", grader_health: "broken")
    expect(repo.main_health).to eq("broken")
  end

  describe "#main_health_broken?" do
    it "returns true when main_health is broken" do
      repo.update!(ci_health: "broken")
      expect(repo).to be_main_health_broken
    end

    it "returns false when main_health is healthy" do
      repo.update!(ci_health: "healthy", grader_health: "healthy")
      expect(repo).not_to be_main_health_broken
    end

    it "returns false when main_health is unknown" do
      expect(repo).not_to be_main_health_broken
    end
  end

  describe "#main_health_unknown?" do
    it "returns true when both signals are unknown" do
      expect(repo).to be_main_health_unknown
    end

    it "returns false when main_health is broken" do
      repo.update!(ci_health: "broken")
      expect(repo).not_to be_main_health_unknown
    end

    it "returns false when main_health is healthy" do
      repo.update!(ci_health: "healthy", grader_health: "healthy")
      expect(repo).not_to be_main_health_unknown
    end
  end

  describe "ci_health and grader_health defaults" do
    it "defaults both to unknown" do
      fresh = Factories.repository
      expect(fresh.ci_health).to eq("unknown")
      expect(fresh.grader_health).to eq("unknown")
    end

    it "rejects invalid health values" do
      repo.ci_health = "invalid"
      expect(repo).not_to be_valid
    end
  end
end
