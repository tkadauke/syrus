require "rails_helper"

RSpec.describe WorkUnitLock do
  def work_unit
    @work_unit ||= begin
      intent = WorkIntent.create!(kind: "initial", state: "requested", scope_type: "job", scope_id: 123)
      WorkUnit.create!(work_intent: intent, kind: "initial", state: "queued", scope_type: "job", scope_id: 123)
    end
  end

  it "sets acquired_at and can be released" do
    lock = described_class.create!(work_unit: work_unit, lock_key: "job:123")

    expect(lock.acquired_at).to be_present
    expect(lock.active_lock_key).to eq("job:123")
    expect(lock).to be_active
    expect {
      lock.release!
    }.to change { lock.reload.released_at }.from(nil)
    expect(lock.active_lock_key).to be_nil
    expect(lock).not_to be_active
  end

  it "rejects duplicate active lock keys" do
    described_class.create!(work_unit: work_unit, lock_key: "job:123")
    duplicate = described_class.new(work_unit: work_unit, lock_key: "job:123")

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:active_lock_key]).to be_present
  end

  # DOC-44 database boundary: the lock models (LockSafety.lean,
  # LockAcquire.lean) assume at most one active lock per key. The validation
  # above runs before the insert, so two concurrent acquirers can both pass
  # it; the unique index is what makes the second insert fail.
  it "has the database reject a second active lock on a key even when validation is skipped" do
    described_class.create!(work_unit: work_unit, lock_key: "job:123")
    racing = described_class.new(work_unit: work_unit, lock_key: "job:123", acquired_at: Time.current, active_lock_key: "job:123")

    expect { racing.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "frees the key in the database once the active lock is released" do
    first = described_class.create!(work_unit: work_unit, lock_key: "job:123")
    first.release!
    racing = described_class.new(work_unit: work_unit, lock_key: "job:123", acquired_at: Time.current, active_lock_key: "job:123")

    expect { racing.save!(validate: false) }.not_to raise_error
  end

  it "allows repeated historical lock keys after release" do
    described_class.create!(work_unit: work_unit, lock_key: "job:123").release!
    duplicate = described_class.new(work_unit: work_unit, lock_key: "job:123")

    expect(duplicate).to be_valid
  end
end
