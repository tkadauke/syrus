require "rails_helper"

RSpec.describe Achievements::Reveals do
  let(:user) { Factories.user }
  let(:other_user) { Factories.user }
  let!(:instance_unlock) { Achievements::Unlock.record!("example.first_epic_landed", subject: Factories.epic).first }
  let!(:own_unlock) { Achievements::Unlock.record!("example.first_job_landed", user_id: user.id, subject: Factories.job).first }
  let!(:other_unlock) { Achievements::Unlock.record!("example.first_job_landed", user_id: other_user.id, subject: Factories.job).first }

  subject(:reveals) { described_class.new(user) }

  it "shows instance unlocks and the user's own, never another user's" do
    expect(reveals.visible_unlocks).to contain_exactly(instance_unlock, own_unlock)
    expect(reveals.pending).to contain_exactly(instance_unlock, own_unlock)
  end

  it "acknowledges per user without touching the unlock or other users' state" do
    before = instance_unlock.reload.attributes
    reveals.acknowledge!(instance_unlock.id)
    reveals.acknowledge!(instance_unlock.id)

    expect(reveals.pending).to eq([ own_unlock ])
    expect(described_class.new(other_user).pending).to contain_exactly(instance_unlock, other_unlock)
    expect(instance_unlock.reload.attributes).to eq(before)
    expect(Achievements::Acknowledgment.where(unlock_id: instance_unlock.id).count).to eq(1)
  end

  it "refuses to acknowledge or replay what the user cannot see" do
    expect { reveals.acknowledge!(other_unlock.id) }.to raise_error(described_class::NotFound)
    expect { reveals.replay!(other_unlock.id) }.to raise_error(described_class::NotFound)
    expect { reveals.acknowledge!(0) }.to raise_error(described_class::NotFound)
  end

  it "replays one reveal for the current user only" do
    reveals.acknowledge!(own_unlock.id)
    reveals.acknowledge!(instance_unlock.id)
    described_class.new(other_user).acknowledge!(instance_unlock.id)

    reveals.replay!(instance_unlock.id)

    expect(reveals.pending).to eq([ instance_unlock ])
    expect(described_class.new(other_user).pending).to eq([ other_unlock ])
  end

  it "resets the current user's acknowledgments and leaves unlocks and timestamps alone" do
    reveals.acknowledge!(own_unlock.id)
    described_class.new(other_user).acknowledge!(other_unlock.id)
    snapshot = Achievements::Unlock.order(:id).map { |unlock| unlock.attributes }

    expect(reveals.reset_own!).to eq(1)

    expect(reveals.pending).to contain_exactly(instance_unlock, own_unlock)
    expect(described_class.new(other_user).pending).to eq([ instance_unlock ])
    expect(Achievements::Unlock.order(:id).map(&:attributes)).to eq(snapshot)
  end

  it "resets everyone's acknowledgments only with the confirmation token" do
    reveals.acknowledge!(own_unlock.id)
    described_class.new(other_user).acknowledge!(other_unlock.id)
    snapshot = Achievements::Unlock.order(:id).map(&:attributes)

    expect { described_class.reset_all!(confirmation: "yes") }.to raise_error(ArgumentError)
    expect(Achievements::Acknowledgment.count).to eq(2)

    expect(described_class.reset_all!(confirmation: described_class::CONFIRM_RESET_ALL)).to eq(2)
    expect(Achievements::Acknowledgment.count).to eq(0)
    expect(Achievements::Unlock.order(:id).map(&:attributes)).to eq(snapshot)
  end

  it "hides unlocks whose definition has left the registry" do
    empty = described_class.new(user, registry: Achievements::Registry.new([]))

    expect(empty.pending).to be_empty
    expect { empty.acknowledge!(own_unlock.id) }.to raise_error(described_class::NotFound)
  end

  it "keeps a single acknowledgment when the same unlock is acknowledged repeatedly" do
    2.times { reveals.acknowledge!(own_unlock.id) }

    expect(Achievements::Acknowledgment.where(unlock_id: own_unlock.id, user_id: user.id).count).to eq(1)
  end
end
