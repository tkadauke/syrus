require "rails_helper"
require "ostruct"

RSpec.describe InputSources::Github do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) do
    Factories.repository(user: user, owner: "acme", name: "widgets", trigger_label: "syrus", polling_enabled: true)
  end
  let(:source) { repository.github_input_source }

  def issue(number: 42, labels: [ "syrus" ], body: "", state: "open", user_login: "reporter")
    OpenStruct.new(
      number: number,
      state: state,
      pull_request: nil,
      title: "Issue #{number}",
      body: body,
      user: OpenStruct.new(login: user_login),
      labels: labels.map { |name| Struct.new(:name, keyword_init: true).new(name: name) }
    )
  end

  describe "#trigger_label" do
    it "returns the config value" do
      expect(source.trigger_label).to eq("syrus")
    end

    it "falls back to 'syrus' when config is empty" do
      source.config = {}
      expect(source.trigger_label).to eq("syrus")
    end
  end

  describe "#dedup_key" do
    it "returns the issue number as a string" do
      iss = issue(number: 77)
      expect(source.dedup_key(iss)).to eq("77")
    end
  end

  describe "#poll!" do
    before do
      allow_any_instance_of(GithubClient).to receive(:linked_open_pr_for_issue).and_return(nil)
    end

    it "creates a Job for a new issue and sets external_ref and input_source" do
      allow_any_instance_of(GithubClient).to receive(:issues_with_label).and_return([ issue ])

      expect { source.poll! }.to change(Job, :count).by(1)

      job = Job.last
      expect(job.external_ref).to eq("42")
      expect(job.input_source).to eq(source)
      expect(job.issue_number).to eq(42)
    end

    it "does not create a duplicate Job when the issue was already ingested" do
      allow_any_instance_of(GithubClient).to receive(:issues_with_label).and_return([ issue ])
      source.poll!
      expect { source.poll! }.not_to change(Job, :count)
    end

    it "closes open Jobs when their source issue is reported closed" do
      job = Factories.job(user: user, repository: repository, issue_number: 42)
      closed = issue(number: 42, state: "closed")
      allow_any_instance_of(GithubClient).to receive(:issues_with_label) do |_client, _slug, _label, state: "open"|
        state == "closed" ? [ closed ] : []
      end

      source.poll!

      expect(job.reload).to be_closed
      expect(job.closure_reason).to eq("issue_closed")
    end

    it "respects polling_enabled and skips disabled sources" do
      source.update!(polling_enabled: false)

      expect(GithubClient).not_to receive(:for)
      expect { source.poll! }.not_to change(Job, :count)
    end

    it "returns without polling when the repository is archived" do
      repository.archive!

      expect(GithubClient).not_to receive(:for)
      expect { source.poll! }.not_to change(Job, :count)
    end

    it "records poll status on the repository" do
      allow_any_instance_of(GithubClient).to receive(:issues_with_label).and_return([])

      source.poll!

      expect(repository.reload.last_poll_status).to eq("ok")
    end

    it "records poll failure on the repository when GitHub raises" do
      allow_any_instance_of(GithubClient).to receive(:issues_with_label).and_raise(Octokit::Error.new)

      expect { source.poll! }.to raise_error(Octokit::Error)
      expect(repository.reload.last_poll_status).to eq("failed")
    end

    it "ingests an Epic declaration without creating a Job" do
      allow_any_instance_of(GithubClient).to receive(:issues_with_label)
        .and_return([ issue(number: 77, body: "Epic: Attachments rollout") ])

      expect { source.poll! }.to change(Epic, :count).by(1).and change(Job, :count).by(0)

      epic = Epic.last
      expect(epic.user).to eq(user)
      expect(epic.repository).to eq(repository)
      expect(epic.title).to eq("Attachments rollout")
    end

    it "sets external_ref and input_source on a preempted Job" do
      linked_pr = { number: 9 }
      allow_any_instance_of(GithubClient).to receive(:linked_open_pr_for_issue).and_return(linked_pr)
      allow_any_instance_of(GithubClient).to receive(:issues_with_label).and_return([ issue ])

      source.poll!

      job = Job.last
      expect(job).to be_closed
      expect(job.closure_reason).to eq("preempted")
      expect(job.external_ref).to eq("42")
      expect(job.input_source).to eq(source)
    end
  end
end
