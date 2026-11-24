require "rails_helper"

RSpec.describe Achievements::Evaluation do
  let(:user) { Factories.user }
  let(:other_user) { Factories.user }

  def job_closed(user_id: user.id, job_id: 41, kind: "direct", origin: "core", closure_reason: "pr_merged", occurred_at: nil)
    Syrus::DomainEvent.new(
      name: "job.closed", occurred_at: occurred_at,
      payload: { job_id: job_id, user_id: user_id, kind: kind, origin: origin, closure_reason: closure_reason }
    )
  end

  def epic_upserted(state: "done", origin: "operator", user_id: user.id, epic_id: 7)
    Syrus::DomainEvent.new(name: "epic.upserted", payload: { epic_id: epic_id, user_id: user_id, state: state, origin: origin })
  end

  describe "user-scoped definitions" do
    it "credits the creator of an operator's direct job once, however often it is delivered" do
      first = described_class.call(job_closed)
      again = described_class.call(job_closed)

      expect(first.map(&:definition_key)).to eq([ "example.first_job_landed" ])
      expect(again).to be_empty
      unlock = Achievements::Unlock.find_by!(definition_key: "example.first_job_landed")
      expect(unlock).to have_attributes(user_id: user.id, subject_type: "job", subject_id: 41)
      expect(unlock.evidence).to eq({ "event" => "job.closed", "closure_reason" => "pr_merged", "kind" => "direct" })
    end

    it "keeps the first unlock when a later event for a different job arrives out of order" do
      described_class.call(job_closed(job_id: 90, occurred_at: 1.hour.ago))
      described_class.call(job_closed(job_id: 12, occurred_at: 2.hours.ago))

      expect(Achievements::Unlock.where(definition_key: "example.first_job_landed").pluck(:subject_id)).to eq([ 90 ])
    end

    it "awards each user their own unlock" do
      described_class.call(job_closed)
      described_class.call(job_closed(user_id: other_user.id, job_id: 42))

      expect(Achievements::Unlock.where(definition_key: "example.first_job_landed").pluck(:user_id)).to contain_exactly(user.id, other_user.id)
    end

    it "does not credit automated or incidental work" do
      [
        job_closed(kind: "cron"), job_closed(kind: "issue"), job_closed(kind: "agent_insight"),
        job_closed(origin: "scheduled_tasks"), job_closed(user_id: nil), job_closed(user_id: 0)
      ].each { |event| described_class.call(event) }

      expect(Achievements::Unlock.where(definition_key: "example.first_job_landed")).to be_empty
    end

    it "does not award a job that closed without landing" do
      described_class.call(job_closed(closure_reason: "cancelled"))

      expect(Achievements::Unlock.count).to eq(0)
    end
  end

  describe "instance-scoped definitions" do
    it "unlocks once for the installation with no user" do
      described_class.call(epic_upserted)
      described_class.call(epic_upserted(user_id: other_user.id, epic_id: 8))

      unlock = Achievements::Unlock.find_by!(definition_key: "example.first_epic_landed")
      expect(Achievements::Unlock.where(definition_key: "example.first_epic_landed").count).to eq(1)
      expect(unlock).to have_attributes(user_id: nil, owner_key: "instance", subject_id: 7)
    end

    it "ignores epics that are not done" do
      described_class.call(epic_upserted(state: "in_progress"))

      expect(Achievements::Unlock.count).to eq(0)
    end

    it "awards the threshold milestone only after enough landed jobs, from current state" do
      (Achievements::Evaluators::Threshold::THRESHOLD - 1).times { Factories.job.update_columns(closure_reason: "pr_merged") }
      described_class.call(job_closed(kind: "cron"))
      expect(Achievements::Unlock.where(definition_key: "example.secret_milestone")).to be_empty

      Factories.job.update_columns(closure_reason: "pr_merged")
      described_class.call(job_closed(kind: "cron"))
      described_class.call(job_closed(kind: "cron"))

      expect(Achievements::Unlock.where(definition_key: "example.secret_milestone").count).to eq(1)
    end
  end

  it "ignores events no adapter understands" do
    expect(described_class.call(Syrus::DomainEvent.new(name: "job.created", payload: {}))).to eq([])
  end

  it "logs and skips a definition with an unknown evaluator without blocking others" do
    broken = Achievements::Definition.build(
      key: "example.broken", scope: :instance, trigger: "epic.upserted", evaluator: "Nope::Missing",
      subject_kinds: %i[epic], category: :milestone, rarity: :common
    )
    registry = Achievements::Registry.new([ broken, *Achievements::Catalog.definitions ])
    allow(Rails.logger).to receive(:error)

    described_class.call(epic_upserted, registry: registry)

    expect(Achievements::Unlock.pluck(:definition_key)).to eq([ "example.first_epic_landed" ])
    expect(Rails.logger).to have_received(:error).with(/unknown evaluator/)
  end

  it "converges when two deliveries race to create the same unlock" do
    allow(Achievements::Unlock).to receive(:find_by).and_wrap_original do |original, *args, **kwargs|
      # Both racers pass the existence check before either has inserted.
      RSpec::Mocks.space.proxy_for(Achievements::Unlock).reset
      Achievements::Unlock.record!("example.first_epic_landed", subject: Achievements::Subject.new(kind: :epic, id: 7))
      nil
    end

    expect { described_class.call(epic_upserted) }.not_to raise_error
    expect(Achievements::Unlock.where(definition_key: "example.first_epic_landed").count).to eq(1)
  end
end
