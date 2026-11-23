require "rails_helper"

RSpec.describe Steps::MergeLockControl do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", auto_merge_enabled: true) }
  let(:job) { Factories.job(user: user, repository: repository, pr_number: 7, branch_name: "syrus/issue-42-1") }
  let(:workflow) { Workflows::AutoMerge.instantiate(job: job) }
  let!(:unit) { attach_work_unit(workflow, state: "running") }
  let(:key) { "merge:repository:#{repository.id}" }

  let(:harness) do
    Class.new do
      include Steps::MergeLockControl
      attr_reader :workflow, :job, :logs

      def initialize(workflow)
        @workflow = workflow
        @job = workflow.job
        @logs = []
      end

      def log(message, **) = @logs << message

      def run_locked(on_timeout: -> { :timed_out }, &block)
        with_merge_lock(context: "auto_merge", on_timeout: on_timeout, &block)
      end
    end.new(workflow)
  end

  before do
    described_class.merge_lock_wait = 0
    described_class.merge_lock_poll = 0
  end

  after do
    described_class.merge_lock_wait = nil
    described_class.merge_lock_poll = nil
  end

  def held? = unit.work_unit_locks.active.exists?(lock_key: key)

  it "holds the lock only while the block runs and releases it after success" do
    harness.run_locked { expect(held?).to be(true) }
    expect(held?).to be(false)
  end

  it "releases the lock when the block raises (failure)" do
    expect { harness.run_locked { raise Steps::Base::StepFailed, "boom" } }.to raise_error(Steps::Base::StepFailed)
    expect(held?).to be(false)
  end

  it "releases the lock when the block defers" do
    harness.run_locked { :deferred }
    expect(held?).to be(false)
  end

  it "does not run the block and calls on_timeout when another unit holds the lock" do
    other_job = Factories.job(user: user, repository: repository, pr_number: 8, branch_name: "syrus/issue-43-1")
    other_workflow = Workflows::AutoMerge.instantiate(job: other_job)
    attach_work_unit(other_workflow, state: "running")
    MergeLock.try_acquire(workflow: other_workflow, job: other_job)

    ran = false
    result = harness.run_locked { ran = true }

    expect(ran).to be(false)
    expect(result).to eq(:timed_out)
    expect(held?).to be(false)
  end

  it "lets the second unit proceed after the first releases (serialized merges)" do
    other_job = Factories.job(user: user, repository: repository, pr_number: 8, branch_name: "syrus/issue-43-1")
    other_workflow = Workflows::AutoMerge.instantiate(job: other_job)
    attach_work_unit(other_workflow, state: "running")
    other = harness.class.new(other_workflow)

    order = []
    harness.run_locked do
      order << :first
      expect(other.run_locked { order << :second_early }).to eq(:timed_out)
    end
    other.run_locked { order << :second }

    expect(order).to eq(%i[first second])
  end
end
