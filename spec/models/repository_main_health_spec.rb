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

  it "is healthy when graders are healthy and CI is explicitly not configured" do
    repo.update!(ci_health: "not_configured", grader_health: "healthy")
    expect(repo.main_health).to eq("healthy")
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

  it "is inconclusive when graders need operator review" do
    repo.update!(ci_health: "not_configured", grader_health: "inconclusive")

    expect(repo.main_health).to eq("inconclusive")
    expect(repo).to be_main_health_inconclusive
    expect(repo).not_to be_main_health_broken
  end

  it "is inconclusive when CI checks were cancelled and graders are healthy" do
    repo.update!(ci_health: "inconclusive", grader_health: "healthy")

    expect(repo.main_health).to eq("inconclusive")
    expect(repo).to be_main_health_inconclusive
    expect(repo).not_to be_main_health_broken
  end

  it "is inconclusive when CI checks were cancelled and graders are unknown" do
    repo.update!(ci_health: "inconclusive", grader_health: "unknown")

    expect(repo.main_health).to eq("inconclusive")
  end

  it "is broken when graders are broken even if CI is inconclusive" do
    repo.update!(ci_health: "inconclusive", grader_health: "broken")

    expect(repo.main_health).to eq("broken")
  end

  it "is unknown when main branch health checking is disabled" do
    repo.update!(main_branch_health_enabled: false, ci_health: "broken", grader_health: "broken")

    expect(repo.main_health).to eq("unknown")
    expect(repo).not_to be_main_health_broken
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

  describe "#main_health_inconclusive?" do
    it "returns true when grader health is inconclusive" do
      repo.update!(ci_health: "not_configured", grader_health: "inconclusive")
      expect(repo).to be_main_health_inconclusive
    end

    it "returns true when CI checks were cancelled" do
      repo.update!(ci_health: "inconclusive", grader_health: "healthy")
      expect(repo).to be_main_health_inconclusive
    end

    it "returns false when main_health is broken" do
      repo.update!(ci_health: "broken", grader_health: "inconclusive")
      expect(repo).not_to be_main_health_inconclusive
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

  describe "main branch health defaults" do
    it "enables health checking and auto-repair for original repositories" do
      fresh = Factories.repository

      expect(fresh.main_branch_health_enabled).to eq(true)
      expect(fresh.main_branch_repair_enabled).to eq(true)
      expect(fresh.main_branch_repair_auto_approve).to eq(false)
    end

    it "enables health checking but disables auto-repair for fork repositories" do
      fork = Factories.repository(upstream_owner: "rails", upstream_name: "rails")

      expect(fork.main_branch_health_enabled).to eq(true)
      expect(fork.main_branch_repair_enabled).to eq(false)
      expect(fork.main_branch_repair_auto_approve).to eq(false)
    end

    it "honors an explicit auto-repair choice for fork repositories" do
      fork = Factories.repository(
        upstream_owner: "rails",
        upstream_name: "rails",
        main_branch_repair_enabled: true,
        main_branch_repair_enabled_explicit: true
      )

      expect(fork.main_branch_health_enabled).to eq(true)
      expect(fork.main_branch_repair_enabled).to eq(true)
    end
  end

  describe "main health poll error streak" do
    it "defaults to zero" do
      fresh = Factories.repository
      expect(fresh.main_health_poll_error_streak).to eq(0)
      expect(fresh.last_main_health_poll_error_at).to be_nil
      expect(fresh).not_to be_main_health_poll_outage
    end

    describe "#record_main_health_poll_error!" do
      it "increments the streak and stamps the error timestamp" do
        expect { repo.record_main_health_poll_error! }
          .to change { repo.reload.main_health_poll_error_streak }.from(0).to(1)

        expect(repo.last_main_health_poll_error_at).to be_present
      end

      it "accumulates across repeated calls" do
        Repository::MAIN_HEALTH_POLL_ERROR_STREAK_THRESHOLD.times { repo.record_main_health_poll_error! }

        expect(repo.reload.main_health_poll_error_streak).to eq(Repository::MAIN_HEALTH_POLL_ERROR_STREAK_THRESHOLD)
      end
    end

    describe "#reset_main_health_poll_error_streak!" do
      it "resets a non-zero streak to zero" do
        repo.update!(main_health_poll_error_streak: 2)

        expect { repo.reset_main_health_poll_error_streak! }
          .to change { repo.reload.main_health_poll_error_streak }.from(2).to(0)
      end

      it "is a no-op when already zero" do
        expect { repo.reset_main_health_poll_error_streak! }.not_to change { repo.updated_at }
      end
    end

    describe "#main_health_poll_outage?" do
      it "is false below the threshold" do
        repo.update!(main_health_poll_error_streak: Repository::MAIN_HEALTH_POLL_ERROR_STREAK_THRESHOLD - 1)
        expect(repo).not_to be_main_health_poll_outage
      end

      it "is true at or above the threshold" do
        repo.update!(main_health_poll_error_streak: Repository::MAIN_HEALTH_POLL_ERROR_STREAK_THRESHOLD)
        expect(repo).to be_main_health_poll_outage
      end
    end
  end
end
