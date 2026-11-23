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

  it "records the pending-decision inversions instead of raising" do
    violation = Syrus::LockOrder::Violation.new(
      held: "User", taking: "Workflow",
      site: "app/services/step_dispatcher.rb:693",
      held_site: "app/services/provider_routing/availability_selector.rb:297"
    )

    expect(Syrus::LockOrder.pending_decision?(violation)).to be(true)
    expect(Syrus::LockOrder.pending_decision?(violation.with(held_site: "app/services/other.rb:1"))).to be(false)
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
