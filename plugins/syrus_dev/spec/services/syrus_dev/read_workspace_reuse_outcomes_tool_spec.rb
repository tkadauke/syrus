require "rails_helper"

RSpec.describe SyrusDev::ReadWorkspaceReuseOutcomesTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "tkadauke", name: "syrus") }
  let(:job) { Factories.job(repository: repository, user: user) }
  let(:run) { job.initial_run }

  before do
    PluginRecord.find_by!(name: "syrus_dev").update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

  it "returns repository-scoped outcomes for an inclusive requested window" do
    WorkspaceReuseOutcomes::Recorder.record(
      run: run,
      kind: "prepare",
      outcome: "reused_from_archive",
      prepare_fingerprint: "abc"
    )
    since = 1.hour.ago
    window_end = 1.hour.from_now

    response = described_class.call(
      server_context: { run_id: run.id },
      since: since.iso8601,
      until_time: window_end.iso8601
    )

    expect(response).not_to be_error
    payload = JSON.parse(response.content.first[:text])
    expect(payload).to include(
      "repository_id" => repository.id,
      "since" => since.iso8601,
      "until_time" => window_end.iso8601
    )
    expect(payload.fetch("groups").sole).to include(
      "prepare_fingerprint" => "abc",
      "reuse_rate" => 1.0
    )
  end

  it "rejects reversed windows" do
    response = described_class.call(
      server_context: { run_id: run.id },
      since: 1.hour.from_now.iso8601,
      until_time: 1.hour.ago.iso8601
    )

    expect(response).to be_error
  end
end
