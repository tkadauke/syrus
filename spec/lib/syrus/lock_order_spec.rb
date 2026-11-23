require "rails_helper"

RSpec.describe Syrus::LockOrder::Checker do
  let!(:job) { Factories.job }
  let!(:workflow) { Workflow.create!(job: job, trigger_kind: "initial") }

  around do |example|
    previous = described_class.mode
    described_class.mode = :raise
    example.run
  ensure
    described_class.mode = previous
  end

  it "accepts locks taken in the global order" do
    expect {
      ActiveRecord::Base.transaction do
        job.lock!
        workflow.lock!
      end
    }.not_to raise_error
  end

  it "rejects a lock on a lower-ranked model while a higher-ranked one is held" do
    expect {
      ActiveRecord::Base.transaction do
        workflow.lock!
        job.lock!
      end
    }.to raise_error(Syrus::LockOrder::Error, /took Job at .* while holding Workflow/)
  end

  it "checks locking relation queries as well as lock!" do
    expect {
      ActiveRecord::Base.transaction do
        workflow.lock!
        Job.where(id: job.id).lock.to_a
      end
    }.to raise_error(Syrus::LockOrder::Error, /took Job at .* while holding Workflow/)
  end

  it "treats a nested transaction as part of the outer one" do
    expect {
      ActiveRecord::Base.transaction do
        workflow.lock!
        ActiveRecord::Base.transaction(requires_new: true) { job.lock! }
      end
    }.to raise_error(Syrus::LockOrder::Error)
  end

  it "starts over in each transaction" do
    ActiveRecord::Base.transaction { workflow.lock! }

    expect { ActiveRecord::Base.transaction { job.lock! } }.not_to raise_error
  end

  it "allows several locks on one model in any order" do
    other = Factories.job(repository: job.repository, issue_number: 99)

    expect {
      ActiveRecord::Base.transaction do
        other.lock!
        job.lock!
      end
    }.not_to raise_error
  end

  it "accepts locking a row again that the transaction already holds" do
    expect {
      ActiveRecord::Base.transaction do
        job.lock!
        workflow.lock!
        job.lock!
      end
    }.not_to raise_error
  end

  it "still rejects another row of a lower-ranked model after a higher-ranked lock" do
    other = Factories.job(repository: job.repository, issue_number: 98)

    expect {
      ActiveRecord::Base.transaction do
        job.lock!
        workflow.lock!
        other.lock!
      end
    }.to raise_error(Syrus::LockOrder::Error, /took Job/)
  end

  # A row the transaction inserted is invisible to every other transaction
  # until commit, so locking it never waits and it cannot be part of a wait
  # cycle. Restarting a Job closes the old one (locking its WorkUnit) and
  # launches the replacement (locking the Workflow it just created) in one
  # transaction; that is not an inversion.
  it "exempts rows the transaction created itself" do
    unit = WorkUnit.where(scope_type: "job", scope_id: job.id).first!

    expect {
      ActiveRecord::Base.transaction do
        unit.lock!
        created = Workflow.create!(job: job, trigger_kind: "initial")
        created.lock!
      end
    }.not_to raise_error
  end

  it "still checks a pre-existing row taken after a self-created one" do
    expect {
      ActiveRecord::Base.transaction do
        created = Workflow.create!(job: job, trigger_kind: "initial")
        created.lock!
        workflow.lock!
        job.lock!
      end
    }.to raise_error(Syrus::LockOrder::Error, /took Job at .* while holding Workflow/)
  end

  it "records the pending-decision inversions instead of raising" do
    violation = Syrus::LockOrder::Violation.new(
      held: "User", taking: "Workflow",
      site: "app/services/step_dispatcher.rb:693",
      held_site: "app/services/provider_routing/availability_selector.rb:297"
    )

    expect(Syrus::LockOrder.pending_decision?(violation)).to be(true)
    expect(Syrus::LockOrder.pending_decision?(violation.with(held_site: "app/services/other.rb:1"))).to be(false)
  end

  # Lead L14: an UPDATE takes an InnoDB row lock just as SELECT ... FOR UPDATE
  # does. Opt-in, for surveying: SYRUS_LOCK_ORDER_WRITES=1.
  describe "write tracking" do
    def with_writes(value)
      previous = ENV["SYRUS_LOCK_ORDER_WRITES"]
      ENV["SYRUS_LOCK_ORDER_WRITES"] = value
      yield
    ensure
      ENV["SYRUS_LOCK_ORDER_WRITES"] = previous
    end

    it "counts a write to a lower-ranked row after a higher-ranked lock when enabled" do
      with_writes("1") do
        expect {
          ActiveRecord::Base.transaction do
            workflow.lock!
            job.update_columns(updated_at: Time.current)
          end
        }.to raise_error(Syrus::LockOrder::Error, /took Job at .* while holding Workflow/)
      end
    end

    it "counts save and destroy as writes too" do
      with_writes("1") do
        expect {
          ActiveRecord::Base.transaction do
            workflow.lock!
            job.touch
          end
        }.to raise_error(Syrus::LockOrder::Error, /took Job/)
      end
    end

    it "ignores writes when not enabled" do
      with_writes(nil) do
        expect {
          ActiveRecord::Base.transaction do
            workflow.lock!
            job.update_columns(updated_at: Time.current)
          end
        }.not_to raise_error
      end
    end
  end

  it "records instead of raising in record mode" do
    described_class.mode = :record
    before = described_class.violations.size

    ActiveRecord::Base.transaction do
      workflow.lock!
      job.lock!
    end

    expect(described_class.violations.size).to eq(before + 1)
    expect(described_class.violations.last).to have_attributes(held: "Workflow", taking: "Job")
    described_class.violations.pop
  end
end
