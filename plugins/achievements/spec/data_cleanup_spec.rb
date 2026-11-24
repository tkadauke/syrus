require "rails_helper"

RSpec.describe Achievements::DataCleanup do
  # Cleanup is installed once the plugin has been enabled on this instance
  # (`ever_enabled`); a never-enabled plugin has no rows to clean.
  before do
    PluginRecord.find_or_create_by!(name: "achievements").update!(enabled: true, disableable: true)
    Syrus::Installer.sync!
  end

  it "removes a destroyed user's unlocks and acknowledgments but keeps instance unlocks" do
    user = Factories.user
    other = Factories.user
    user_unlock, = Achievements::Unlock.record!("example.first_job_landed", user_id: user.id)
    instance_unlock, = Achievements::Unlock.record!("example.first_epic_landed")
    instance_unlock.acknowledge!(user.id)
    instance_unlock.acknowledge!(other.id)

    user.destroy!

    expect(Achievements::Unlock.exists?(user_unlock.id)).to be(false)
    expect(Achievements::Unlock.exists?(instance_unlock.id)).to be(true)
    expect(instance_unlock.acknowledgments.pluck(:user_id)).to eq([ other.id ])
  end

  it "keeps an unlock and its evidence when the job subject is destroyed" do
    job = Factories.job
    unlock, = Achievements::Unlock.record!("example.first_job_landed", user_id: Factories.user.id, subject: job, evidence: { "k" => 1 })

    job.destroy!

    expect(unlock.reload).to have_attributes(subject_type: "job", subject_id: job.id, evidence: { "k" => 1 })
  end

  it "still runs while the plugin is disabled" do
    PluginRecord.find_by!(name: "achievements").update!(enabled: false)
    Syrus::Installer.sync!
    user = Factories.user
    unlock, = Achievements::Unlock.record!("example.first_job_landed", user_id: user.id)

    user.destroy!

    expect(Achievements::Unlock.exists?(unlock.id)).to be(false)
  end
end
