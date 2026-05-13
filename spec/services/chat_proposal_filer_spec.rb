require "rails_helper"

RSpec.describe ChatProposalFiler do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:session) { ChatSession.create!(repository: repository, user: user) }

  def proposal(slug:, title:, kind: "syrus_issue", body: "Body for #{title}", labels: nil)
    ChatProposal.create!(
      chat_session: session,
      slug: slug,
      title: title,
      body: body,
      kind: kind,
      labels: labels
    )
  end

  def depends_on(proposal, dependency)
    ChatProposalDependency.create!(proposal: proposal, depends_on: dependency)
  end

  describe "#file!" do
    it "files a leaf after its upstream closure and wires Job dependencies" do
      root = proposal(slug: "a", title: "Root")
      middle = proposal(slug: "b", title: "Middle")
      leaf = proposal(slug: "c", title: "Leaf")
      depends_on(middle, root)
      depends_on(leaf, middle)

      expect {
        described_class.new(user: user, repository: repository).file!([ leaf ])
      }.to change(Job, :count).by(3)
        .and change(JobDependency, :count).by(2)
        .and have_enqueued_job(RunJob).exactly(:once)

      expect([ root, middle, leaf ].map { |p| p.reload.state }).to all(eq("filed"))
      expect([ root, middle, leaf ].map(&:job)).to all(be_present)
      expect(middle.job.dependencies.first.depends_on_job).to eq(root.job)
      expect(leaf.job.dependencies.first.depends_on_job).to eq(middle.job)
    end

    it "dedupes shared upstream proposals for bulk filing" do
      root = proposal(slug: "root", title: "Root")
      left = proposal(slug: "left", title: "Left")
      right = proposal(slug: "right", title: "Right")
      depends_on(left, root)
      depends_on(right, root)

      result = described_class.new(user: user, repository: repository).file!([ left, right ])

      expect(result.jobs.map(&:issue_title)).to eq([ "Root", "Left", "Right" ])
      expect(Job.count).to eq(3)
      expect(JobDependency.count).to eq(2)
      expect(left.reload.job.dependencies.first.depends_on_job).to eq(root.reload.job)
      expect(right.reload.job.dependencies.first.depends_on_job).to eq(root.job)
    end

    it "warns for mixed Syrus and GitHub proposals and only wires Syrus Job dependencies" do
      github = proposal(slug: "gh", title: "GitHub issue", kind: "github_issue", labels: %(["bug"]))
      syrus = proposal(slug: "syrus", title: "Syrus issue")
      depends_on(syrus, github)
      client = instance_double(GithubClient)
      allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
      expect(client).to receive(:create_issue)
        .with("acme/widgets", title: "GitHub issue", body: "Body for GitHub issue", labels: %w[bug syrus])
        .and_return(Struct.new(:number).new(123))

      result = described_class.new(user: user, repository: repository).file!([ syrus ])

      expect(result.warnings.join).to include("Dependencies are wired only between Syrus job proposals")
      expect(github.reload).to be_filed
      expect(github.github_issue_number).to eq(123)
      expect(github.job).to be_nil
      expect(syrus.reload.job).to be_present
      expect(JobDependency.count).to eq(0)
    end

    it "rolls back proposal and Job changes when filing fails" do
      root = proposal(slug: "root", title: "Root")
      leaf = proposal(slug: "leaf", title: "Leaf")
      depends_on(leaf, root)
      filer = described_class.new(user: user, repository: repository)
      calls = 0
      allow(filer).to receive(:create_adhoc_job).and_wrap_original do |original, prop|
        calls += 1
        raise ActiveRecord::RecordInvalid.new(Job.new) if calls == 2

        original.call(prop)
      end

      expect {
        expect { filer.file!([ leaf ]) }.to raise_error(ActiveRecord::RecordInvalid)
      }.not_to change(Job, :count)

      expect(root.reload).to be_pending
      expect(leaf.reload).to be_pending
      expect(JobDependency.count).to eq(0)
    end
  end
end
