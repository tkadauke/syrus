require "rails_helper"

RSpec.describe ChatEpicProposalMaterializer do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def epic_proposal
    chat_session.proposals.create!(
      slug: "m3",
      title: "M3 proposals",
      body: "Group cards.",
      kind: "epic",
      repository: repository
    )
  end

  def child_for(proposal, slug)
    proposal.child_proposals.create!(
      chat_session: chat_session,
      slug: slug,
      title: slug.titleize,
      body: "Build #{slug}.",
      repository: repository
    )
  end

  def depend_on(proposal, dependency)
    ChatProposalDependency.create!(proposal: proposal, depends_on: dependency)
  end

  it "materializes the Epic, child Jobs, and sibling Job dependencies in one transaction" do
    proposal = epic_proposal
    prerequisite_epic = Factories.epic(user: user, repository: repository)
    prerequisite_job = Factories.job_record(user: user, repository: repository, issue_number: 7)
    proposal.update!(depends_on_job_ids: [ prerequisite_job.id ])
    schema = proposal.child_proposals.create!(
      chat_session: chat_session,
      slug: "schema",
      title: "Schema",
      body: "Persist it.",
      repository: repository
    )
    ui = proposal.child_proposals.create!(
      chat_session: chat_session,
      slug: "ui",
      title: "UI",
      body: "Render it.",
      repository: repository,
      depends_on_epic_ids: [ prerequisite_epic.id ]
    )
    ChatProposalDependency.create!(proposal: ui, depends_on: schema)

    result = described_class.new(user: user).file!(proposal)

    expect(result.epic).to have_attributes(title: "M3 proposals", repository: repository)
    expect(proposal.reload).to be_confirmed
    expect(proposal.epic).to eq(result.epic)
    expect(result.jobs.map(&:issue_title)).to contain_exactly("Schema", "UI")
    expect(result.jobs).to all(be_blocked_by_epic)
    expect(result.jobs).to all(have_attributes(epic: result.epic))
    expect(ui.reload.job.dependencies.first.depends_on_job).to eq(schema.reload.job)
    expect(ui.job.dependencies.map(&:depends_on_epic)).to include(prerequisite_epic)
    expect(result.epic.dependencies.map(&:depends_on_job)).to include(prerequisite_job)
    expect(chat_session.reload.attached_epics).to contain_exactly(result.epic)
    expect(chat_session.attached_jobs).to contain_exactly(*result.jobs)
  end

  it "blocks child Jobs when an EpicDependency wired during file! is invisible to a stale association cache" do
    in_progress_epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    blocking_job = Factories.job_record(user: user, repository: repository, issue_number: 77)
    proposal = epic_proposal
    proposal.update!(target_epic: in_progress_epic, depends_on_job_ids: [ blocking_job.id ])
    proposal.child_proposals.create!(
      chat_session: chat_session,
      slug: "work",
      title: "Work",
      body: "Build it.",
      repository: repository
    )
    # Simulate stale cache: load the empty collection before file! wires the dep.
    proposal.target_epic.dependencies.load

    result = described_class.new(user: user).file!(proposal)

    expect(result.jobs).to all(be_blocked_by_epic)
  end

  it "materializes child Jobs under an existing target Epic without creating a new Epic" do
    target_epic = Factories.epic(user: user, repository: repository, title: "PO-authored backlog", state: "backlog")
    proposal = epic_proposal
    proposal.update!(target_epic: target_epic, title: target_epic.title, body: "Technically elaborated.")
    proposal.child_proposals.create!(
      chat_session: chat_session,
      slug: "child",
      title: "Build first slice",
      body: "Implement the first technical slice.",
      repository: repository
    )

    expect {
      @result = described_class.new(user: user).file!(proposal)
    }.not_to change(Epic, :count)

    result = @result
    expect(result.epic).to eq(target_epic)
    expect(proposal.reload).to be_confirmed
    expect(proposal.epic).to eq(target_epic)
    expect(result.jobs.sole.epic).to eq(target_epic)
    expect(chat_session.reload.attached_epics).to contain_exactly(target_epic)
  end

  it "does not duplicate attachments when confirmation is retried" do
    proposal = epic_proposal
    proposal.child_proposals.create!(
      chat_session: chat_session,
      slug: "child",
      title: "Child",
      body: "Build it.",
      repository: repository
    )
    materializer = described_class.new(user: user)

    materializer.file!(proposal)

    expect {
      expect {
        materializer.file!(proposal.reload)
      }.to raise_error(ArgumentError, /proposal is no longer proposed/)
    }.not_to change(ChatAttachment, :count)
  end

  it "materializes Epic dependencies from proposal slug tokens" do
    prerequisite = chat_session.proposals.create!(
      slug: "some-slug",
      title: "Prerequisite",
      body: "Do this first.",
      kind: "epic",
      repository: repository,
      epic: Factories.epic(user: user, repository: repository),
      state: "confirmed",
      filed_at: Time.current,
      confirmed_at: Time.current
    )
    proposal = epic_proposal
    proposal.update!(epic_depends_on_tokens: JSON.generate([ prerequisite.slug ]))
    proposal.child_proposals.create!(
      chat_session: chat_session,
      slug: "child",
      title: "Child",
      body: "Build it.",
      repository: repository
    )

    result = described_class.new(user: user).file!(proposal)

    expect(result.epic.reload.depends_on_epics).to contain_exactly(prerequisite.epic)
  end

  it "wires dependent confirmed Epic proposals when the upstream Epic is confirmed later" do
    dependent = epic_proposal
    dependent.update!(epic_depends_on_tokens: JSON.generate([ "upstream" ]))
    dependent.child_proposals.create!(
      chat_session: chat_session,
      slug: "dependent-child",
      title: "Dependent child",
      body: "Build it.",
      repository: repository
    )
    upstream = chat_session.proposals.create!(
      slug: "upstream",
      title: "Upstream",
      body: "Do this first.",
      kind: "epic",
      repository: repository
    )
    upstream.child_proposals.create!(
      chat_session: chat_session,
      slug: "upstream-child",
      title: "Upstream child",
      body: "Build it.",
      repository: repository
    )

    materializer = described_class.new(user: user)
    dependent_result = materializer.file!(dependent)
    upstream_result = materializer.file!(upstream)

    expect(dependent.reload.epic_depends_on_tokens).to eq(JSON.generate([ "epic:#{upstream_result.epic.id}" ]))
    expect(dependent_result.epic.reload.depends_on_epics).to contain_exactly(upstream_result.epic)
  end

  it "materializes Epic dependencies from string-encoded Epic ids" do
    prerequisite = Factories.epic(user: user, repository: repository)
    proposal = epic_proposal
    proposal.update!(epic_depends_on_tokens: JSON.generate([ "epic:#{prerequisite.id}" ]))
    proposal.child_proposals.create!(
      chat_session: chat_session,
      slug: "child",
      title: "Child",
      body: "Build it.",
      repository: repository
    )

    result = described_class.new(user: user).file!(proposal)

    expect(result.epic.reload.depends_on_epics).to contain_exactly(prerequisite)
  end

  it "accepts a linear child Job chain under the default linear policy" do
    proposal = epic_proposal
    first = child_for(proposal, "first")
    second = child_for(proposal, "second")
    third = child_for(proposal, "third")
    depend_on(second, first)
    depend_on(third, second)

    result = described_class.new(user: user).file!(proposal)

    expect(result.jobs.map(&:issue_title)).to eq([ "First", "Second", "Third" ])
    expect(second.reload.job.dependencies.map(&:depends_on_job)).to contain_exactly(first.reload.job)
    expect(third.reload.job.dependencies.map(&:depends_on_job)).to contain_exactly(second.reload.job)
  end

  it "accepts unordered child proposals when dependencies still form one chain" do
    proposal = epic_proposal
    third = child_for(proposal, "third")
    first = child_for(proposal, "first")
    second = child_for(proposal, "second")
    depend_on(second, first)
    depend_on(third, second)

    result = described_class.new(user: user).file!(proposal)

    expect(result.jobs.map(&:issue_title)).to eq([ "First", "Second", "Third" ])
  end

  it "accepts redundant transitive sibling edges in a linear chain" do
    proposal = epic_proposal
    first = child_for(proposal, "first")
    second = child_for(proposal, "second")
    third = child_for(proposal, "third")
    depend_on(second, first)
    depend_on(third, second)
    depend_on(third, first)

    expect {
      described_class.new(user: user).file!(proposal)
    }.to change(Job, :count).by(3)
  end

  it "rejects fan-in child dependency graphs under the default linear policy" do
    proposal = epic_proposal
    left = child_for(proposal, "left")
    right = child_for(proposal, "right")
    merge = child_for(proposal, "merge")
    depend_on(merge, left)
    depend_on(merge, right)

    expect {
      described_class.new(user: user).file!(proposal)
    }.to raise_error(ArgumentError, /single chain.*left, right/)
    expect(proposal.reload).to be_proposed
  end

  it "rejects fan-out child dependency graphs under the default linear policy" do
    proposal = epic_proposal
    root = child_for(proposal, "root")
    left = child_for(proposal, "left")
    right = child_for(proposal, "right")
    depend_on(left, root)
    depend_on(right, root)

    expect {
      described_class.new(user: user).file!(proposal)
    }.to raise_error(ArgumentError, /single chain.*left, right/)
    expect(proposal.reload).to be_proposed
  end

  it "rejects multiple root and leaf child graphs under the default linear policy" do
    proposal = epic_proposal
    first = child_for(proposal, "first")
    second = child_for(proposal, "second")
    third = child_for(proposal, "third")
    fourth = child_for(proposal, "fourth")
    depend_on(second, first)
    depend_on(fourth, third)

    expect {
      described_class.new(user: user).file!(proposal)
    }.to raise_error(ArgumentError, /single chain.*first, third/)
    expect(proposal.reload).to be_proposed
  end

  it "allows nonlinear child graphs when the proposal has an explicit override" do
    proposal = epic_proposal
    proposal.update!(nonlinear_dependency_override: true)
    root = child_for(proposal, "root")
    left = child_for(proposal, "left")
    right = child_for(proposal, "right")
    depend_on(left, root)
    depend_on(right, root)

    expect {
      described_class.new(user: user).file!(proposal)
    }.to change(Job, :count).by(3)
  end

  it "creates pending Job dependencies for unresolved cross-card Job proposal references" do
    prerequisite = chat_session.proposals.create!(
      slug: "upstream-job",
      title: "Upstream",
      body: "Do this first.",
      kind: "job",
      repository: repository
    )
    proposal = epic_proposal
    child = proposal.child_proposals.create!(
      chat_session: chat_session,
      slug: "child",
      title: "Child",
      body: "Build it.",
      repository: repository
    )
    ChatProposalDependency.create!(proposal: child, depends_on: prerequisite)

    result = described_class.new(user: user).file!(proposal)

    dependency = child.reload.job.dependencies.first
    expect(result.jobs.first.dependencies).to contain_exactly(dependency)
    expect(dependency).to have_attributes(
      depends_on_job_id: nil,
      unresolved_chat_proposal_id: prerequisite.id,
      source: "manual",
      created_by_user: user
    )
  end

  it "resolves pending cross-card Job proposal dependencies when the upstream proposal is confirmed" do
    prerequisite = chat_session.proposals.create!(
      slug: "upstream-job",
      title: "Upstream",
      body: "Do this first.",
      kind: "job",
      repository: repository
    )
    proposal = epic_proposal
    child = proposal.child_proposals.create!(
      chat_session: chat_session,
      slug: "child",
      title: "Child",
      body: "Build it.",
      repository: repository
    )
    ChatProposalDependency.create!(proposal: child, depends_on: prerequisite)

    described_class.new(user: user).file!(proposal)
    ChatProposalFiler.new(user: user, repository: repository).file!([ prerequisite ])

    dependency = child.reload.job.dependencies.first
    expect(dependency).to be_resolved
    expect(dependency.depends_on_job).to eq(prerequisite.reload.job)
    expect(dependency.unresolved_chat_proposal_id).to be_nil
  end

  it "excludes rejected child Jobs from materialization" do
    proposal = epic_proposal
    kept = proposal.child_proposals.create!(
      chat_session: chat_session,
      slug: "kept",
      title: "Kept",
      body: "Build it.",
      repository: repository
    )
    proposal.child_proposals.create!(
      chat_session: chat_session,
      slug: "rejected",
      title: "Rejected",
      body: "Do not build it.",
      repository: repository,
      state: "rejected",
      rejected_at: Time.current
    )

    result = described_class.new(user: user).file!(proposal)

    expect(result.jobs.size).to eq(1)
    expect(result.jobs.first.issue_title).to eq("Kept")
    expect(kept.reload).to be_confirmed
    expect(chat_session.proposals.find_by!(slug: "rejected")).to be_rejected
  end

  it "rejects archived proposal repositories before creating records" do
    repository.archive!
    proposal = epic_proposal

    expect {
      expect {
        described_class.new(user: user).file!(proposal)
      }.to raise_error(ArgumentError, /repository #{repository.slug} is archived/)
    }.to change(Epic, :count).by(0).and change(Job, :count).by(0)

    expect(proposal.reload).to be_proposed
  end

  it "rolls back the Epic when a child Job cannot be created" do
    other_repository = Factories.repository(user: user)
    proposal = epic_proposal
    proposal.update!(nonlinear_dependency_override: true)
    proposal.child_proposals.create!(
      chat_session: chat_session,
      slug: "good",
      title: "Good",
      body: "Same repo.",
      repository: repository
    )
    proposal.child_proposals.create!(
      chat_session: chat_session,
      slug: "bad",
      title: "Bad",
      body: "Different repo.",
      repository: other_repository
    )

    expect {
      expect {
        described_class.new(user: user).file!(proposal)
      }.to raise_error(ActiveRecord::RecordInvalid, /Epic must belong to the same repository/)
    }.to change(Epic, :count).by(0).and change(Job, :count).by(0)

    expect(proposal.reload).to be_proposed
    expect(proposal.epic).to be_nil
  end
end
