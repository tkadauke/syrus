require "rails_helper"

RSpec.describe CloseEpicTrackingIssueJob do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def epic(state: "done", issue_url: "https://github.com/acme/widgets/issues/4798")
    Epic.create!(
      user: user,
      repository: repository,
      title: "Surface doctrine",
      description: "Epic: Surface doctrine",
      state: state,
      github_issue_url: issue_url
    )
  end

  def stub_client(issue_state:)
    client = instance_double(GithubClient)
    allow(GithubClient).to receive(:for).and_return(client)
    allow(client).to receive(:fetch_issue).and_return(Struct.new(:state).new(issue_state))
    allow(client).to receive(:close_issue)
    client
  end

  it "closes the tracking issue of a done Epic" do
    client = stub_client(issue_state: "open")
    target = epic

    described_class.new.perform(target.id)

    expect(client).to have_received(:close_issue).with(repository.slug, 4798)
  end

  it "does nothing when the issue is already closed" do
    client = stub_client(issue_state: "closed")

    described_class.new.perform(epic.id)

    expect(client).not_to have_received(:close_issue)
  end

  it "does nothing for an Epic that is not done" do
    client = stub_client(issue_state: "open")

    described_class.new.perform(epic(state: "in_progress").id)

    expect(client).not_to have_received(:close_issue)
  end

  it "does nothing for an Epic with no tracking issue" do
    client = stub_client(issue_state: "open")

    described_class.new.perform(epic(issue_url: nil).id)

    expect(client).not_to have_received(:close_issue)
  end

  it "does nothing for a missing Epic" do
    client = stub_client(issue_state: "open")

    expect { described_class.new.perform(-1) }.not_to raise_error
    expect(client).not_to have_received(:close_issue)
  end

  # A GitHub hiccup must never be able to fail an Epic's completion.
  it "swallows GitHub errors" do
    client = instance_double(GithubClient)
    allow(GithubClient).to receive(:for).and_return(client)
    allow(client).to receive(:fetch_issue).and_raise(StandardError, "boom")

    expect { described_class.new.perform(epic.id) }.not_to raise_error
  end

  describe "Epic#github_issue_number" do
    it "extracts the issue number from the tracking URL" do
      expect(epic.github_issue_number).to eq(4798)
    end

    it "is nil when the Epic has no tracking issue" do
      expect(epic(issue_url: nil).github_issue_number).to be_nil
    end
  end
end
