require "rails_helper"

RSpec.describe EpicChainSplice do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:epic) { Factories.epic(user: user, repository: repository) }
  let(:session) { ChatSession.create!(user: user, repository: repository) }

  def epic_job(number, state: "queued")
    Factories.job_record(user: user, repository: repository, epic: epic, issue_number: number, state: state)
  end

  def chain!(upstream, downstream, **attrs)
    JobDependency.create!(job: downstream, depends_on_job: upstream, source: "manual", **attrs)
  end

  let!(:a) { epic_job(1) }
  let!(:b) { epic_job(2) }
  let!(:edge) { chain!(a, b, satisfaction_mode: "landed") }

  describe ".plan!" do
    it "returns the anchor and its downstream edge" do
      plan = described_class.plan!(epic: epic, anchor_job_id: a.id)

      expect(plan.anchor).to eq(a)
      expect(plan.downstream_job).to eq(b)
    end

    it "has no downstream edge when the anchor is the tail" do
      expect(described_class.plan!(epic: epic, anchor_job_id: b.id).downstream_edge).to be_nil
    end

    it "rejects an anchor outside the Epic" do
      other = Factories.job_record(user: user, repository: repository, issue_number: 50)

      expect { described_class.plan!(epic: epic, anchor_job_id: other.id) }
        .to raise_error(described_class::Rejected, /not a Job in/)
    end

    it "rejects when the downstream Job has already started" do
      b.update_columns(state: "running")

      expect { described_class.plan!(epic: epic, anchor_job_id: a.id) }
        .to raise_error(described_class::Rejected, /has already started/)
    end
  end

  describe ".apply!" do
    it "re-points the downstream edge to the new tail, preserving its satisfaction mode, and chains the head onto the anchor" do
      head = epic_job(3)
      tail = epic_job(4)
      chain!(head, tail)

      described_class.apply!(epic: epic, anchor_job_id: a.id, head_job: head, tail_job: tail, user: user)

      expect(edge.reload).to have_attributes(depends_on_job_id: tail.id, job_id: b.id, satisfaction_mode: "landed")
      expect(head.dependencies.sole.depends_on_job).to eq(a)
      expect(b.dependencies.sole.depends_on_job).to eq(tail)
      expect(JobDependency.where(depends_on_job_id: a.id).pluck(:job_id)).to eq([ head.id ])
    end

    it "is equivalent to an append when the anchor is the tail" do
      head = epic_job(3)

      described_class.apply!(epic: epic, anchor_job_id: b.id, head_job: head, tail_job: head, user: user)

      expect(head.dependencies.sole.depends_on_job).to eq(b)
    end
  end

  describe ".order_segment" do
    it "orders a chain head first" do
      expect(described_class.order_segment(%w[x y z], "z" => [ "y" ], "y" => [ "x" ])).to eq(%w[x y z])
    end

    it "rejects a forked segment" do
      expect { described_class.order_segment(%w[x y z], "y" => [ "x" ], "z" => [ "x" ]) }.to raise_error(ArgumentError, /single chain/)
    end
  end

  describe "ChatProposalFiler integration" do
    it "files a Job proposal spliced into the middle, leaving one chain" do
      proposal = ChatProposal.create!(chat_session: session, slug: "mid", title: "Middle", body: "Body", kind: "job",
                                      repository: repository, target_epic: epic, insert_after_job_id: a.id)

      result = ChatProposalFiler.new(user: user, repository: repository).file!([ proposal ])

      job = result.jobs.sole
      expect(job.dependencies.sole.depends_on_job).to eq(a)
      expect(b.dependencies.sole).to have_attributes(depends_on_job_id: job.id, satisfaction_mode: "landed")
      expect(proposal.reload.insertion_json).to include(insert_after_slug: a.slug, insert_before_slug: b.slug)
    end

    it "rejects at confirmation time when the downstream Job started after the proposal was made" do
      proposal = ChatProposal.create!(chat_session: session, slug: "mid", title: "Middle", body: "Body", kind: "job",
                                      repository: repository, target_epic: epic, insert_after_job_id: a.id)
      b.update_columns(state: "running")

      expect { ChatProposalFiler.new(user: user, repository: repository).file!([ proposal ]) }
        .to raise_error(ArgumentError, /already started/)
      expect(proposal.reload).to be_proposed
      expect(edge.reload.depends_on_job_id).to eq(a.id)
    end
  end

  describe "ChatEpicProposalMaterializer integration" do
    def card(**attrs)
      session.proposals.create!(slug: "bundle", title: "Bundle", body: "Group.", kind: "epic", repository: repository,
                                target_epic: epic, insert_after_job_id: a.id, **attrs)
    end

    def child(parent, slug, position)
      parent.child_proposals.create!(chat_session: session, slug: slug, title: slug.titleize, body: "Build #{slug}.",
                                     repository: repository, child_position: position)
    end

    it "splices a child chain between the anchor and its downstream Job" do
      proposal = card
      first = child(proposal, "first", 0)
      second = child(proposal, "second", 1)
      ChatProposalDependency.create!(proposal: second, depends_on: first)

      result = ChatEpicProposalMaterializer.new(user: user).file!(proposal)

      first_job, second_job = result.jobs
      expect(first_job.dependencies.sole.depends_on_job).to eq(a)
      expect(second_job.dependencies.sole.depends_on_job).to eq(first_job)
      expect(b.dependencies.sole).to have_attributes(depends_on_job_id: second_job.id, satisfaction_mode: "landed")
      expect(JobDependency.where(job_id: epic.jobs.select(:id), depends_on_job_id: epic.jobs.select(:id)).count).to eq(3)
      expect(proposal.reload.insertion_json).to include(insert_after_slug: a.slug, insert_before_slug: b.slug)
    end

    it "rejects an explicit dependency on the first child" do
      proposal = card
      child(proposal, "first", 0).update!(depends_on_job_ids: [ b.id ])

      expect { ChatEpicProposalMaterializer.new(user: user).file!(proposal) }
        .to raise_error(ArgumentError, /explicit dependencies on the first child/)
    end

    it "rejects an anchor that is not in the Epic" do
      other = Factories.job_record(user: user, repository: repository, issue_number: 60)
      proposal = card(insert_after_job_id: other.id)
      child(proposal, "first", 0)

      expect { ChatEpicProposalMaterializer.new(user: user).file!(proposal) }
        .to raise_error(ArgumentError, /not a Job in/)
    end
  end

  describe "JobDependency validation stays strict for ordinary callers" do
    it "still rejects a single-edge fork and a single-edge merge" do
      c = epic_job(3)

      expect(JobDependency.new(job: c, depends_on_job: a, source: "manual")).not_to be_valid
      expect(JobDependency.new(job: b, depends_on_job: c, source: "manual")).not_to be_valid
    end
  end
end
