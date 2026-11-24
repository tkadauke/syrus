require "rails_helper"

RSpec.describe Achievements::UiSlots do
  let(:user) { Factories.user }
  let(:job) { Factories.job(repository: Factories.repository(user: user)) }

  before { allow(Achievements).to receive(:enabled?).and_return(true) }

  def slots(slot: "job.detail", context: { job: job, user: user }) = described_class.ui_slots(slot: slot, context: context)

  it "offers the reveal host only while a reveal is pending for this Job" do
    expect(slots).to eq([])

    unlock = Achievements::Unlock.record!("example.first_job_landed", user_id: user.id, subject: job).first
    panel = slots.first
    expect(panel).to include(component: "achievements/JobReveal", props: { job_id: job.id })

    Achievements::Reveals.new(user).acknowledge!(unlock.id)
    expect(slots).to eq([])
  end

  it "ignores other slots, anonymous viewers, and a disabled plugin" do
    Achievements::Unlock.record!("example.first_job_landed", user_id: user.id, subject: job)

    expect(slots(slot: "job.detail.tab")).to eq([])
    expect(slots(context: { job: job, user: nil })).to eq([])
    allow(Achievements).to receive(:enabled?).and_return(false)
    expect(slots).to eq([])
  end
end
