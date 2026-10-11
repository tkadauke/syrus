require "rails_helper"

RSpec.describe RefreshCognitiveDebtSnapshotsJob do
  let(:user) { Factories.user }

  it "warms the snapshot for each polled repository" do
    polled = Factories.repository(user: user, owner: "acme", name: "polled")
    polled.update!(polling_enabled: true)

    expect(App::CognitiveDebtPayload).to receive(:refresh!).with(repository: polled).and_return({})

    described_class.perform_now
  end

  it "skips repositories that are not polled" do
    quiet = Factories.repository(user: user, owner: "acme", name: "quiet")
    quiet.update!(polling_enabled: false)

    expect(App::CognitiveDebtPayload).not_to receive(:refresh!)

    described_class.perform_now
  end

  # One repository's rollup must not stop the rest being warmed: a stale entry
  # just falls back to computing inline on the next request.
  it "continues after a repository raises" do
    first = Factories.repository(user: user, owner: "acme", name: "first")
    second = Factories.repository(user: user, owner: "acme", name: "second")
    [ first, second ].each { |r| r.update!(polling_enabled: true) }

    allow(App::CognitiveDebtPayload).to receive(:refresh!).with(repository: first).and_raise(StandardError, "boom")
    expect(App::CognitiveDebtPayload).to receive(:refresh!).with(repository: second).and_return({})

    expect { described_class.perform_now }.not_to raise_error
  end
end
