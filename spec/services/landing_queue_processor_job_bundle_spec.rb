require "rails_helper"

RSpec.describe LandingQueueProcessor, "epicless job bundle integration" do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, auto_merge_enabled: true) }

  def approved_job(issue_number, priority: "medium")
    Factories.job_record(
      user: user, repository: repository,
      issue_number: issue_number, state: "approved", priority: priority,
      pr_number: 500 + issue_number, branch_name: "syrus/issue-#{issue_number}"
    )
  end

  def approved_external_pr_job(external_pr_number:)
    # external_pr Jobs must be created in :implemented state (validated on create).
    Job.create!(
      user: user, owner_user: user, repository: repository,
      kind: "external_pr", issue_number: nil,
      external_pr_number: external_pr_number, state: "implemented"
    ).tap do |job|
      job.approve!(via: "operator")
    end
  end

  def enable_flag
    Feature.create!(slug: "epicless_job_bundling", category: "Labs", name: "Epicless Job bundling", enabled: true)
  end

  def bundle_members!(*jobs, priority: "medium")
    train = MergeTrain.create!(repository: repository, base_branch: repository.default_branch, priority: priority)
    jobs.each_with_index do |job, index|
      job.start_landing!
      job.save!
      MergeTrainMember.create!(merge_train: train, job: job, position: index)
    end
    train
  end

  describe "blockage" do
    it "keeps epicless Jobs off the per-Job path once a same-tier bundle can form" do
      enable_flag
      approved_job(1)
      second = approved_job(2)

      entry = described_class.entries(Job.where(id: second.id)).first
      expect(entry.blocked_reason).to eq({ key: "waiting_epicless_bundle" })
    end

    it "does not block a lone ready epicless Job (falls through to per-Job auto_merge)" do
      enable_flag
      job = approved_job(1)

      entry = described_class.entries(Job.where(id: job.id)).first
      expect(entry.blocked_reason).to be_blank
    end

    it "does not block epicless Jobs for the bundle reason when the flag is off" do
      approved_job(1)
      second = approved_job(2)

      entry = described_class.entries(Job.where(id: second.id)).first
      expect(entry.blocked_reason).not_to eq({ key: "waiting_epicless_bundle" })
    end

    it "excludes an external_pr Job from bundling even with other same-tier candidates" do
      enable_flag
      approved_job(1)
      approved_job(2)
      external = approved_external_pr_job(external_pr_number: 7)

      entry = described_class.entries(Job.where(id: external.id)).first
      expect(entry.blocked_reason).to be_blank
    end

    it "groups dispatched bundle members under one job_bundle landing unit" do
      enable_flag
      a = approved_job(1)
      b = approved_job(2)
      train = bundle_members!(a, b)

      entries = described_class.entries(Job.where(id: [ a.id, b.id ]))

      expect(entries.map(&:landing_unit_key).uniq).to eq([ "job_bundle:#{train.id}" ])
    end
  end

  describe "#call" do
    it "dispatches a job bundle for ready same-tier epicless Jobs instead of per-Job auto-merges" do
      enable_flag
      approved_job(1)
      approved_job(2)
      allow(JobBundleDispatcher).to receive(:try_dispatch!).and_return(Object.new)

      described_class.call

      expect(JobBundleDispatcher).to have_received(:try_dispatch!).with(repository)
      expect(Workflow.where(trigger_kind: "auto_merge").count).to eq(0)
    end

    it "dispatches ExternalPrMerge for an external_pr Job instead of sweeping it into a bundle" do
      enable_flag
      approved_job(1)
      approved_job(2)
      external = approved_external_pr_job(external_pr_number: 7)
      allow(JobBundleDispatcher).to receive(:try_dispatch!).and_return(Object.new)

      described_class.try_land!(external)

      expect(external.reload).to be_landing
      expect(Workflow.where(job: external).pluck(:trigger_kind)).to eq([ "external_pr_merge" ])
    end

    it "routes try_land! for a bundle-eligible epicless Job to the bundle dispatcher" do
      enable_flag
      a = approved_job(1)
      approved_job(2)
      allow(JobBundleDispatcher).to receive(:try_dispatch!).and_return(nil)

      described_class.new.try_land!(a)

      expect(JobBundleDispatcher).to have_received(:try_dispatch!).with(repository)
    end
  end

  describe "urgent-tier isolation" do
    it "blocks a non-urgent Job while an urgent same-tier bundle can form" do
      enable_flag
      approved_job(1, priority: "urgent")
      approved_job(2, priority: "urgent")
      non_urgent = approved_job(3)

      entry = described_class.entries(Job.where(id: non_urgent.id)).first
      expect(entry.blocked_reason).to eq({ key: "urgent_job_active" })
    end

    it "does not block an urgent bundle member against its own bundle" do
      enable_flag
      a = approved_job(1, priority: "urgent")
      approved_job(2, priority: "urgent")

      entry = described_class.entries(Job.where(id: a.id)).first
      expect(entry.blocked_reason).not_to eq({ key: "urgent_job_active" })
    end

    it "does not block a non-urgent Job that a member of an active urgent bundle depends on" do
      enable_flag
      non_urgent = approved_job(1)
      urgent_a = approved_job(2, priority: "urgent")
      urgent_b = approved_job(3, priority: "urgent")
      JobDependency.create!(job: urgent_a, depends_on_job: non_urgent, source: "manual")
      bundle_members!(urgent_a, urgent_b, priority: "urgent")

      entry = described_class.entries(Job.where(id: non_urgent.id)).first

      expect(entry.blocked_reason).to be_blank
    end

    it "blocks a non-urgent Job when an active urgent bundle has no dependency on it" do
      enable_flag
      non_urgent = approved_job(1)
      urgent_a = approved_job(2, priority: "urgent")
      urgent_b = approved_job(3, priority: "urgent")
      bundle_members!(urgent_a, urgent_b, priority: "urgent")

      entry = described_class.entries(Job.where(id: non_urgent.id)).first

      expect(entry.blocked_reason).to eq({ key: "urgent_job_active" })
    end
  end
end
