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

  describe ".on_branch" do
    it "returns only snapshots for the given branch" do
      main_snap    = create_snapshot(branch: "main")
      feature_snap = create_snapshot(branch: "feature/x")

      results = described_class.on_branch("main")
      expect(results).to include(main_snap)
      expect(results).not_to include(feature_snap)
    end
  end

  describe ".since" do
    it "returns snapshots created at or after the given time" do
      old_snap = create_snapshot
      old_snap.update_columns(created_at: 10.days.ago)
      new_snap = create_snapshot

      results = described_class.since(5.days.ago)
      expect(results).to include(new_snap)
      expect(results).not_to include(old_snap)
    end
  end

  describe ".daily_averages" do
    it "returns daily averages grouped by date on the default branch" do
      repository.update!(default_branch: "main")

      snap1 = create_snapshot(branch: "main", lines_pct: 80, branches_pct: 60, functions_pct: 90)
      snap1.update_columns(created_at: 2.days.ago.beginning_of_day + 1.hour)
      snap2 = create_snapshot(branch: "main", lines_pct: 90, branches_pct: 70, functions_pct: 100)
      snap2.update_columns(created_at: 2.days.ago.beginning_of_day + 2.hours)
      snap3 = create_snapshot(branch: "main", lines_pct: 50, branches_pct: 40, functions_pct: 60)
      snap3.update_columns(created_at: 1.day.ago.beginning_of_day + 1.hour)

      results = described_class.daily_averages(repository: repository).to_a

      expect(results.size).to eq(2)
      two_days_row = results.find { |r| r.date.to_s == 2.days.ago.to_date.to_s }
      one_day_row  = results.find { |r| r.date.to_s == 1.day.ago.to_date.to_s }

      expect(two_days_row.avg_lines_pct.to_f).to be_within(0.01).of(85.0)
      expect(two_days_row.avg_branches_pct.to_f).to be_within(0.01).of(65.0)
      expect(two_days_row.avg_functions_pct.to_f).to be_within(0.01).of(95.0)
      expect(one_day_row.avg_lines_pct.to_f).to be_within(0.01).of(50.0)
    end

    it "excludes snapshots on other branches" do
      repository.update!(default_branch: "main")
      feature_snap = create_snapshot(branch: "feature/x", lines_pct: 70, branches_pct: 50, functions_pct: 80)
      feature_snap.update_columns(created_at: 1.day.ago)

      results = described_class.daily_averages(repository: repository)
      expect(results).to be_empty
    end

    it "excludes snapshots older than the requested days window" do
      repository.update!(default_branch: "main")
      old_snap = create_snapshot(branch: "main", lines_pct: 99)
      old_snap.update_columns(created_at: 40.days.ago)

      results = described_class.daily_averages(repository: repository, days: 30)
      expect(results).to be_empty
    end

    it "returns results in ascending date order" do
      repository.update!(default_branch: "main")
      snap_yesterday = create_snapshot(branch: "main", lines_pct: 70)
      snap_yesterday.update_columns(created_at: 1.day.ago.beginning_of_day + 1.hour)
      snap_today = create_snapshot(branch: "main", lines_pct: 80)
      snap_today.update_columns(created_at: Time.current.beginning_of_day + 1.hour)

      results = described_class.daily_averages(repository: repository)
      dates = results.map { |r| r.date.to_s }
      expect(dates).to eq(dates.sort)
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
