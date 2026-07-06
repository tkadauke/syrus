require "rails_helper"

RSpec.describe CoverageSnapshot do
  let(:job)        { Factories.job }
  let(:workflow)   { job.workflows.first }
  let(:repository) { job.repository }

  def build_snapshot(**attrs)
    described_class.new({
      repository: repository,
      workflow:   workflow,
      sha:        "abc123",
      branch:     "main"
    }.merge(attrs))
  end

  def create_snapshot(**attrs)
    build_snapshot(**attrs).tap(&:save!)
  end

  describe "associations" do
    it "belongs to repository" do
      snapshot = create_snapshot
      expect(snapshot.repository).to eq(repository)
    end

    it "belongs to workflow" do
      snapshot = create_snapshot
      expect(snapshot.workflow).to eq(workflow)
    end

    it "belongs to job (optional)" do
      with_job    = create_snapshot(job: job)
      without_job = create_snapshot(job: nil)

      expect(with_job.job).to eq(job)
      expect(without_job.job).to be_nil
    end
  end

  describe "data column" do
    it "defaults to an empty hash on initialize" do
      snapshot = build_snapshot
      expect(snapshot.data).to eq({})
    end

    it "round-trips per-file summary data" do
      snapshot = create_snapshot(data: {
        "app/models/user.rb" => { "lines_pct" => 95.2, "branches_pct" => 88.0 }
      })
      reloaded = described_class.find(snapshot.id)
      expect(reloaded.data["app/models/user.rb"]).to eq("lines_pct" => 95.2, "branches_pct" => 88.0)
    end
  end

  describe "decimal coverage fields" do
    it "persists and retrieves fractional percentages" do
      snapshot = create_snapshot(
        lines_pct:     92.5,
        branches_pct:  78.0,
        functions_pct: 100.0,
        pr_delta_pct:  -2.5
      )
      reloaded = described_class.find(snapshot.id)
      expect(reloaded.lines_pct.to_f).to eq(92.5)
      expect(reloaded.branches_pct.to_f).to eq(78.0)
      expect(reloaded.functions_pct.to_f).to eq(100.0)
      expect(reloaded.pr_delta_pct.to_f).to eq(-2.5)
    end
  end

  describe ".for_branch" do
    it "returns only snapshots for the given branch" do
      main_snap   = create_snapshot(branch: "main")
      feature_snap = create_snapshot(branch: "feature/x")

      results = described_class.for_branch("main")
      expect(results).to include(main_snap)
      expect(results).not_to include(feature_snap)
    end
  end

  describe ".recent" do
    it "returns the n most recent snapshots in descending order" do
      old_snap   = create_snapshot
      old_snap.update_columns(created_at: 2.hours.ago)
      mid_snap   = create_snapshot
      mid_snap.update_columns(created_at: 1.hour.ago)
      fresh_snap = create_snapshot

      results = described_class.recent(2).to_a
      expect(results.first).to eq(fresh_snap)
      expect(results.second).to eq(mid_snap)
      expect(results).not_to include(old_snap)
    end
  end

  describe ".on_default_branch" do
    it "returns snapshots whose branch matches the repository default_branch" do
      repository.update!(default_branch: "main")
      on_default  = create_snapshot(branch: "main")
      off_default = create_snapshot(branch: "feature/something")

      results = described_class.on_default_branch
      expect(results).to include(on_default)
      expect(results).not_to include(off_default)
    end

    it "respects each repository's own default_branch" do
      other_repo = Factories.repository(user: repository.user, default_branch: "trunk")
      other_wf   = Workflow.create!(job: Factories.job(repository: other_repo), trigger_kind: "initial")

      trunk_snap = described_class.create!(
        repository: other_repo,
        workflow:   other_wf,
        sha:        "def456",
        branch:     "trunk"
      )

      repository.update!(default_branch: "main")
      main_snap = create_snapshot(branch: "main")

      results = described_class.on_default_branch
      expect(results).to include(trunk_snap, main_snap)
    end
  end
end
