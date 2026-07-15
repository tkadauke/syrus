require "rails_helper"

RSpec.describe ChatProposalFiler do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:session) { ChatSession.create!(repository: repository, user: user) }

  def proposal(slug:, title:, kind: "syrus_issue", body: "Body for #{title}", labels: nil, **attrs)
    ChatProposal.create!({
      chat_session: session,
      slug: slug,
      title: title,
      body: body,
      kind: kind,
      labels: labels
    }.merge(attrs))
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

      expect([ root, middle, leaf ].map { |p| p.reload.state }).to all(eq("confirmed"))
      expect([ root, middle, leaf ].map(&:job)).to all(be_present)
      expect(middle.job.dependencies.first.depends_on_job).to eq(root.job)
      expect(leaf.job.dependencies.first.depends_on_job).to eq(middle.job)
    end

    it "wires Job proposal dependencies on existing Epics" do
      prerequisite = Factories.epic(user: user, repository: repository)
      job_proposal = proposal(
        slug: "job-after-epic",
        title: "Job after Epic",
        depends_on_epic_ids: [ prerequisite.id ]
      )

      expect {
        described_class.new(user: user, repository: repository).file!([ job_proposal ])
      }.to change(JobDependency, :count).by(1)

      dependency = job_proposal.reload.job.dependencies.first
      expect(dependency).to have_attributes(
        depends_on_epic_id: prerequisite.id,
        depends_on_job_id: nil,
        source: "manual",
        created_by_user: user
      )
    end

    it "wires Job proposal dependencies on existing Jobs" do
      prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 7)
      job_proposal = proposal(
        slug: "job-after-job",
        title: "Job after Job",
        depends_on_job_ids: [ prerequisite.id ]
      )

      expect {
        described_class.new(user: user, repository: repository).file!([ job_proposal ])
      }.to change(JobDependency, :count).by(1)

      dependency = job_proposal.reload.job.dependencies.first
      expect(dependency).to have_attributes(
        depends_on_job_id: prerequisite.id,
        depends_on_epic_id: nil,
        source: "manual",
        created_by_user: user
      )
    end

    it "attaches created Jobs to the originating chat session" do
      job_proposal = proposal(slug: "job-attachment", title: "Attached job")

      described_class.new(user: user, repository: repository).file!([ job_proposal ])

      expect(session.reload.attached_jobs).to contain_exactly(job_proposal.reload.job)
    end

    it "does not duplicate Job attachments when filing is retried after confirmation" do
      job_proposal = proposal(slug: "job-retry", title: "Retry job")
      filer = described_class.new(user: user, repository: repository)

      filer.file!([ job_proposal ])

      expect {
        filer.file!([ job_proposal.reload ])
      }.not_to change { session.reload.job_attachments.count }
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

    it "files Epic proposals and wires Epic dependencies" do
      root = proposal(slug: "root-epic", title: "Root Epic", kind: "epic")
      leaf = proposal(slug: "leaf-epic", title: "Leaf Epic", kind: "epic")
      depends_on(leaf, root)

      result = described_class.new(user: user, repository: repository).file!([ leaf ])

      expect(result.epics.map(&:title)).to eq([ "Root Epic", "Leaf Epic" ])
      expect(root.reload).to be_confirmed
      expect(leaf.reload).to be_confirmed
      expect(root.epic).to have_attributes(title: "Root Epic", description: "Body for Root Epic")
      expect(leaf.epic.depends_on_epics).to contain_exactly(root.epic)
    end

    it "wires Epic proposal slug dependencies when the dependent is confirmed first" do
      upstream = proposal(slug: "upstream-epic", title: "Upstream Epic", kind: "epic")
      dependent = proposal(
        slug: "dependent-epic",
        title: "Dependent Epic",
        kind: "epic",
        epic_depends_on_tokens: JSON.generate([ upstream.slug ])
      )
      filer = described_class.new(user: user, repository: repository)

      dependent_result = filer.file!([ dependent ])
      upstream_result = filer.file!([ upstream ])

      dependent_epic = dependent_result.epics.first
      upstream_epic = upstream_result.epics.first
      expect(dependent.reload.epic_depends_on_tokens).to eq(JSON.generate([ "epic:#{upstream_epic.id}" ]))
      expect(dependent_epic.reload.depends_on_epics).to contain_exactly(upstream_epic)
    end

    it "wires Epic proposal slug dependencies when the upstream is already confirmed" do
      upstream = proposal(slug: "upstream-epic", title: "Upstream Epic", kind: "epic")
      dependent = proposal(
        slug: "dependent-epic",
        title: "Dependent Epic",
        kind: "epic",
        epic_depends_on_tokens: JSON.generate([ upstream.slug ])
      )
      filer = described_class.new(user: user, repository: repository)

      upstream_result = filer.file!([ upstream ])
      dependent_result = filer.file!([ dependent ])

      expect(dependent.reload.epic_depends_on_tokens).to eq(JSON.generate([ "epic:#{upstream_result.epics.first.id}" ]))
      expect(dependent_result.epics.first.reload.depends_on_epics).to contain_exactly(upstream_result.epics.first)
    end

    it "attaches created Epics to the originating chat session" do
      epic_proposal = proposal(slug: "epic-attachment", title: "Attached Epic", kind: "epic")

      described_class.new(user: user, repository: repository).file!([ epic_proposal ])

      expect(session.reload.attached_epics).to contain_exactly(epic_proposal.reload.epic)
    end

    it "wires Epic proposal dependencies on existing Jobs" do
      prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 7)
      epic_proposal = proposal(
        slug: "epic-after-job",
        title: "Epic after Job",
        kind: "epic",
        depends_on_job_ids: [ prerequisite.id ]
      )

      expect {
        described_class.new(user: user, repository: repository).file!([ epic_proposal ])
      }.to change(EpicDependency, :count).by(1)

      dependency = epic_proposal.reload.epic.dependencies.first
      expect(dependency).to have_attributes(
        depends_on_job_id: prerequisite.id,
        depends_on_epic_id: nil,
        derived: false
      )
    end

    it "rolls back proposal and Job changes when filing fails" do
      root = proposal(slug: "root", title: "Root")
      leaf = proposal(slug: "leaf", title: "Leaf")
      depends_on(leaf, root)
      filer = described_class.new(user: user, repository: repository)
      calls = 0
      allow(filer).to receive(:create_direct_job).and_wrap_original do |original, prop|
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

    it "materializes an Epic-only proposal without creating child Jobs" do
      epic_proposal = proposal(
        slug: "epic-marble",
        title: "Marble backlog",
        body: "A place for proposals to stand upright.",
        kind: "epic"
      )

      job_count = Job.count
      expect {
        described_class.new(user: user, repository: repository).file!([ epic_proposal ])
      }.to change(Epic, :count).by(1)
      expect(Job.count).to eq(job_count)

      epic = epic_proposal.reload.epic
      expect(epic).to have_attributes(
        repository: repository,
        title: "Marble backlog",
        description: "A place for proposals to stand upright."
      )
      expect(epic_proposal).to be_confirmed
    end

    it "rejects archived repositories before filing proposals" do
      repository.archive!
      job_proposal = proposal(slug: "job-hidden", title: "Hidden job")

      expect {
        expect {
          described_class.new(user: user, repository: repository).file!([ job_proposal ])
        }.to raise_error(ArgumentError, /repository acme\/widgets is archived/)
      }.to change(Job, :count).by(0).and change(Epic, :count).by(0)

      expect(job_proposal.reload).to be_proposed
    end

    it "materializes a Job proposal under its target Epic" do
      epic = Factories.epic(user: user, repository: repository, title: "Forum")
      job_proposal = proposal(
        slug: "job-labels",
        title: "Add labels",
        body: "The columns are tired of guessing.",
        kind: "job",
        target_epic: epic
      )

      expect {
        described_class.new(user: user, repository: repository).file!([ job_proposal ])
      }.to change(Job, :count).by(1)

      job = job_proposal.reload.job
      expect(job).to have_attributes(
        repository: repository,
        epic: epic,
        kind: "direct",
        issue_title: "Add labels",
        issue_body: "The columns are tired of guessing."
      )
    end

    it "materializes a Job proposal without an Epic when no target Epic is set" do
      job_proposal = proposal(
        slug: "job-standalone",
        title: "Standalone inscription",
        kind: "job"
      )

      described_class.new(user: user, repository: repository).file!([ job_proposal ])

      expect(job_proposal.reload.job.epic).to be_nil
    end

    describe "media_ids" do
      def whiteboard_snapshot(chat_session:)
        WhiteboardSnapshot.create!(
          chat_session: chat_session,
          name: "My snapshot",
          scene_json: { "elements" => [{ "id" => "abc" }], "appState" => {} },
          snapshot_kind: "manual",
          element_count: 1
        )
      end

      def chat_image_document(chat_session:)
        doc = Document.new(kind: "file", attachable: user, user: user)
        doc.file.attach(io: StringIO.new("pixels"), filename: "photo.png", content_type: "image/png")
        doc.save!
        ChatAttachment.create!(
          chat_session: chat_session,
          attachable: doc,
          suppress_header_broadcast: true
        )
        doc
      end

      it "creates a pending_snapshot Document for each snapshot:ID media ref" do
        snapshot = whiteboard_snapshot(chat_session: session)
        job_proposal = proposal(
          slug: "media-snap",
          title: "Snappy job",
          media_ids: ["snapshot:#{snapshot.id}"]
        )

        described_class.new(user: user, repository: repository).file!([ job_proposal ])

        job = job_proposal.reload.job
        expect(job.job_attachments.count).to eq(1)
        attachment = job.job_attachments.first
        expect(attachment).to have_attributes(
          kind: "pending_snapshot",
          title: "My snapshot",
          source_url: "snapshot:#{snapshot.id}"
        )
        expect(attachment.content_cache).to include("abc")
      end

      it "creates a file Document for each chat_image:ID media ref by re-associating the blob" do
        doc = chat_image_document(chat_session: session)
        job_proposal = proposal(
          slug: "media-img",
          title: "Image job",
          media_ids: ["chat_image:#{doc.id}"]
        )

        described_class.new(user: user, repository: repository).file!([ job_proposal ])

        job = job_proposal.reload.job
        expect(job.job_attachments.count).to eq(1)
        attachment = job.job_attachments.first
        expect(attachment).to have_attributes(
          kind: "file",
          title: doc.title,
          source_url: "chat_image:#{doc.id}"
        )
        expect(attachment.file.blob).to eq(doc.file.blob)
      end

      it "skips a snapshot media ref silently when the snapshot was deleted after proposal creation" do
        snapshot = whiteboard_snapshot(chat_session: session)
        job_proposal = proposal(
          slug: "media-missing-snap",
          title: "Missing snapshot job",
          media_ids: ["snapshot:#{snapshot.id}"]
        )
        snapshot.destroy!

        expect {
          described_class.new(user: user, repository: repository).file!([ job_proposal ])
        }.not_to raise_error

        expect(job_proposal.reload.job.job_attachments).to be_empty
      end

      it "skips a chat_image media ref silently when the document was deleted after proposal creation" do
        doc = chat_image_document(chat_session: session)
        job_proposal = proposal(
          slug: "media-missing-img",
          title: "Missing image job",
          media_ids: ["chat_image:#{doc.id}"]
        )
        doc.file.purge
        ChatAttachment.where(attachable: doc).destroy_all
        doc.destroy!

        expect {
          described_class.new(user: user, repository: repository).file!([ job_proposal ])
        }.not_to raise_error

        expect(job_proposal.reload.job.job_attachments).to be_empty
      end
    end
  end
end
