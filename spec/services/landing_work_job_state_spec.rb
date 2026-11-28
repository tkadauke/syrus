require "rails_helper"

RSpec.describe LandingWorkJobState do
  around do |example|
    previous_mode = Syrus::LockOrder::Checker.mode
    previous_writes = ENV["SYRUS_LOCK_ORDER_WRITES"]
    ENV["SYRUS_LOCK_ORDER_WRITES"] = "1"
    example.run
  ensure
    Syrus::LockOrder::Checker.mode = previous_mode
    ENV["SYRUS_LOCK_ORDER_WRITES"] = previous_writes
  end

  def checked
    Syrus::LockOrder::Checker.mode = :raise
    yield
  ensure
    Syrus::LockOrder::Checker.mode = :record
  end

  # Regression, found by the simulator fuzzer (an operator pausing and
  # unpausing an Epic member while its landing ran): moving an Epic member to
  # landing locked the Job and then, rolling its state up, the Epic -- the
  # reverse of the parents-before-children row-lock order.
  it "moves an Epic member to landing taking the Epic's lock before the Job's" do
    epic = Factories.epic
    job = Factories.job(repository: epic.repository, user: epic.user, epic: epic)
    job.update_columns(state: "running")
    workflow = WorkUnits::Launcher.instantiate(kind: "auto_merge", job: job.reload)

    landed = checked { described_class.ensure_landing!(job: job.reload, workflow: workflow, reason: "spec") }

    expect(landed).to be(true)
    expect(job.reload).to be_landing
  end
end
