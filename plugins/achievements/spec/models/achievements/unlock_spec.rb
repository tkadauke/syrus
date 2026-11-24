require "rails_helper"

RSpec.describe Achievements::Unlock do
  let(:user) { Factories.user }
  let(:other_user) { Factories.user }

  it "records a user unlock once per user and preserves first-unlock evidence" do
    job = Factories.job
    unlock, created = described_class.record!("example.first_job_landed", user_id: user.id, subject: job, evidence: { "pr" => 12 })
    again, created_again = described_class.record!("example.first_job_landed", user_id: user.id, subject: job, evidence: { "pr" => 99 })

    expect(created).to be(true)
    expect(created_again).to be(false)
    expect(again).to eq(unlock)
    expect(again.evidence).to eq({ "pr" => 12 })
    expect(unlock).to have_attributes(subject_type: "job", subject_id: job.id, owner_key: "user:#{user.id}", definition_version: 1)
    expect(described_class.record!("example.first_job_landed", user_id: other_user.id, subject: job).last).to be(true)
  end

  it "records instance unlocks once per installation regardless of user" do
    epic = Factories.epic
    unlock, = described_class.record!("example.first_epic_landed", user_id: user.id, subject: epic)
    again, created = described_class.record!("example.first_epic_landed", user_id: other_user.id, subject: epic)

    expect(created).to be(false)
    expect(again).to eq(unlock)
    expect(unlock).to have_attributes(user_id: nil, owner_key: "instance", scope: "instance")
  end

  it "records a definition that exists only in the supplied registry" do
    custom = Achievements::Definition.build(
      key: "custom.only_here", scope: :user, trigger: "job.landed",
      evaluator: "Achievements::Evaluators::FirstOccurrence", subject_kinds: %i[job],
      category: :landing, rarity: :common
    )
    registry = Achievements::Registry.new([ custom ])

    unlock, created = described_class.record!("custom.only_here", user_id: user.id, subject: Factories.job, registry: registry)

    expect(created).to be(true)
    expect(unlock).to be_persisted
    expect(Achievements::Registry.default.find("custom.only_here")).to be_nil
  end

  it "enforces uniqueness in the database" do
    described_class.record!("example.first_job_landed", user_id: user.id)
    duplicate = described_class.new(definition_key: "example.first_job_landed", definition_version: 1, scope: "user",
      owner_key: "user:#{user.id}", user_id: user.id, unlocked_at: Time.current)
    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "resolves a lost create race to the existing row" do
    existing, = described_class.record!("example.first_job_landed", user_id: user.id)
    allow(described_class).to receive(:find_by).and_return(nil, existing)
    allow_any_instance_of(described_class).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique)

    expect(described_class.record!("example.first_job_landed", user_id: user.id)).to eq([ existing, false ])
  end

  it "rejects unknown definitions, missing users, and subject kinds the definition does not allow" do
    expect { described_class.record!("nope") }.to raise_error(KeyError)
    expect { described_class.record!("example.first_job_landed") }.to raise_error(ActiveRecord::RecordInvalid, /User/)
    expect { described_class.record!("example.first_job_landed", user_id: user.id, subject: Factories.epic) }
      .to raise_error(ActiveRecord::RecordInvalid, /Subject type/)
  end

  describe "evidence" do
    def attempt(evidence) = described_class.record!("example.first_job_landed", user_id: user.id, evidence: evidence)

    it "accepts bounded primitive JSON" do
      expect { attempt({ "a" => [ 1, 2.5, true, nil, "s" ], "b" => { "c" => "d" } }) }.not_to raise_error
    end

    it "rejects symbols keys, objects, deep nesting, long strings, and oversized payloads" do
      expect { attempt({ a: 1 }) }.to raise_error(ActiveRecord::RecordInvalid, /non-string keys/)
      expect { attempt({ "a" => Time.current }) }.to raise_error(ActiveRecord::RecordInvalid, /non-primitive/)
      expect { attempt({ "a" => { "b" => { "c" => 1 } } }) }.to raise_error(ActiveRecord::RecordInvalid, /nested deeper/)
      expect { attempt({ "a" => "x" * 501 }) }.to raise_error(ActiveRecord::RecordInvalid, /longer than/)
      expect { attempt({ "a" => Array.new(30) { "x" * 400 } }) }.to raise_error(ActiveRecord::RecordInvalid, /larger than/)
    end
  end

  describe "acknowledgments" do
    it "are per user and idempotent, including for instance unlocks" do
      unlock, = described_class.record!("example.first_epic_landed")
      unlock.acknowledge!(user.id)
      unlock.acknowledge!(user.id)
      unlock.acknowledge!(other_user.id)

      expect(unlock.acknowledgments.count).to eq(2)
      expect(unlock.acknowledged_by?(user.id)).to be(true)
      expect(described_class.record!("example.first_epic_landed").first.acknowledgments.count).to eq(2)
    end

    it "only lets the attributed user acknowledge a user unlock" do
      unlock, = described_class.record!("example.first_job_landed", user_id: user.id)
      expect { unlock.acknowledge!(other_user.id) }.to raise_error(ArgumentError)
    end

    it "enforces uniqueness in the database" do
      unlock, = described_class.record!("example.first_epic_landed")
      unlock.acknowledge!(user.id)
      expect { Achievements::Acknowledgment.new(unlock_id: unlock.id, user_id: user.id, acknowledged_at: Time.current).save!(validate: false) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
