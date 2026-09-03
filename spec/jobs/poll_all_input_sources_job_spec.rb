require "rails_helper"

RSpec.describe PollAllInputSourcesJob do
  it "does not enqueue disabled source providers", requires_plugin: "linear_source" do
    repository = Factories.repository
    source = InputSources::Linear.create!(repository: repository, user: repository.user, polling_enabled: true)
    PluginRecord.find_by!(name: "linear_source").update!(enabled: false)

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollInputSourceJob).with(source.id)
  end
end
