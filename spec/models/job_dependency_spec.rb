require "rails_helper"

RSpec.describe JobDependency do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def issue_job(number)
    Job.create!(user: user, repository: repository, issue_number: number)
  end

  it "rejects self references" do
    job = issue_job(1)
    dependency = described_class.new(job: job, depends_on_job: job, source: "manual")

    expect(dependency).not_to be_valid
    expect(dependency.errors[:depends_on_job]).to include("can't be the same Job")
  end

  it "rejects a direct cycle" do
    a = issue_job(1)
    b = issue_job(2)
    described_class.create!(job: a, depends_on_job: b, source: "manual")

    dependency = described_class.new(job: b, depends_on_job: a, source: "manual")

    expect(dependency).not_to be_valid
    expect(dependency.errors[:depends_on_job]).to include("would create a cycle")
  end

  it "rejects an indirect cycle" do
    a = issue_job(1)
    b = issue_job(2)
    c = issue_job(3)
    described_class.create!(job: a, depends_on_job: b, source: "manual")
    described_class.create!(job: b, depends_on_job: c, source: "manual")

    dependency = described_class.new(job: c, depends_on_job: a, source: "manual")

    expect(dependency).not_to be_valid
    expect(dependency.errors[:depends_on_job]).to include("would create a cycle")
  end

  describe "pending (unresolved) rows" do
    it "accepts a row with unresolved fields and no depends_on_job" do
      job = issue_job(1)
      dep = described_class.new(job: job, unresolved_owner: "acme",
                                unresolved_repo: "widgets", unresolved_number: 42,
                                source: "parsed")
      expect(dep).to be_valid
      dep.save!
      expect(dep).to be_pending
      expect(dep.unresolved_slug).to eq("acme/widgets#42")
    end

    it "rejects a row with neither depends_on_job nor unresolved fields" do
      job = issue_job(1)
      dep = described_class.new(job: job, source: "parsed")
      expect(dep).not_to be_valid
    end

    it "rejects a row with both depends_on_job and unresolved fields" do
      a = issue_job(1)
      b = issue_job(2)
      dep = described_class.new(job: a, depends_on_job: b,
                                unresolved_owner: "x", unresolved_repo: "y", unresolved_number: 3,
                                source: "parsed")
      expect(dep).not_to be_valid
    end

    it "rejects a pending row with partial unresolved fields" do
      job = issue_job(1)
      dep = described_class.new(job: job, unresolved_owner: "acme", source: "parsed")
      expect(dep).not_to be_valid
    end

    it "promotes a pending row to resolved via #resolve!" do
      job = issue_job(1)
      target = issue_job(42)
      dep = described_class.create!(job: job, unresolved_owner: repository.owner,
                                    unresolved_repo: repository.name, unresolved_number: 42,
                                    source: "parsed")

      dep.resolve!(depends_on_job: target)
      expect(dep.reload).to be_resolved
      expect(dep.depends_on_job).to eq(target)
      expect(dep.unresolved_owner).to be_nil
      expect(dep.unresolved_number).to be_nil
    end

    it "scopes pending vs resolved correctly" do
      a = issue_job(1)
      b = issue_job(2)
      resolved = described_class.create!(job: a, depends_on_job: b, source: "manual")
      pending = described_class.create!(job: a, unresolved_owner: "x",
                                        unresolved_repo: "y", unresolved_number: 99,
                                        source: "parsed")

      expect(described_class.resolved).to include(resolved)
      expect(described_class.resolved).not_to include(pending)
      expect(described_class.pending).to include(pending)
      expect(described_class.pending).not_to include(resolved)
    end

    it "resolves pending Epic issue references through #referenced_epic" do
      epic = Factories.epic(
        user: user,
        repository: repository,
        github_issue_url: "https://github.com/#{repository.owner}/#{repository.name}/issues/99",
        state: "done",
        done_at: Time.current
      )
      job = issue_job(1)
      dependency = described_class.create!(
        job: job,
        unresolved_owner: repository.owner,
        unresolved_repo: repository.name,
        unresolved_number: 99,
        source: "parsed"
      )

      expect(dependency.referenced_epic).to eq(epic)
      expect(dependency).to be_dependency_succeeded
    end

    it "classifies actionable and orphaned pending proposal references" do
      chat = ChatSession.create!(user: user, repository: repository)
      actionable = ChatProposal.create!(chat_session: chat, slug: "still-proposed", title: "Still proposed", body: "Wait.")
      orphaned = ChatProposal.create!(chat_session: chat, slug: "withdrawn", title: "Withdrawn", body: "Gone.", state: "withdrawn")
      job = issue_job(1)

      actionable_dependency = described_class.create!(job: job, unresolved_chat_proposal: actionable, source: "manual")
      orphaned_dependency = described_class.create!(job: job, unresolved_chat_proposal: orphaned, source: "manual")

      expect(actionable_dependency.pending_reference_kind).to eq("proposal")
      expect(actionable_dependency.pending_reference_state).to eq("actionable")
      expect(orphaned_dependency.pending_reference_kind).to eq("proposal")
      expect(orphaned_dependency.pending_reference_state).to eq("orphaned")
    end
  end

  describe "explicit Epic targets" do
    it "accepts depends_on_epic as a single target" do
      job = issue_job(1)
      epic = Factories.epic(user: user, repository: repository)

      dependency = described_class.new(job: job, depends_on_epic: epic, source: "manual")

      expect(dependency).to be_valid
      expect(dependency).not_to be_pending
    end

    it "rejects rows with multiple targets set" do
      job = issue_job(1)
      target = issue_job(2)
      epic = Factories.epic(user: user, repository: repository)

      dependency = described_class.new(job: job, depends_on_job: target, depends_on_epic: epic, source: "manual")

      expect(dependency).not_to be_valid
      expect(dependency.errors[:base]).to include("must reference exactly one dependency target")
    end

    it "checks dependency success from the target Epic state" do
      job = issue_job(1)
      epic = Factories.epic(user: user, repository: repository, state: "ready")
      dependency = described_class.create!(job: job, depends_on_epic: epic, source: "manual")

      expect(dependency).not_to be_dependency_succeeded

      epic.override_state!("done")

      expect(dependency.reload).to be_dependency_succeeded
    end
  end

  describe "#dependency_succeeded?" do
    it "keeps success-mode dependencies blocked when the target Job is cancelled" do
      prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 10, state: "closed", closure_reason: "cancelled")
      dependent = Factories.job_record(user: user, repository: repository, issue_number: 11, state: "queued")

      dependency = described_class.create!(job: dependent, depends_on_job: prerequisite, source: "manual")

      expect(dependency.satisfaction_mode).to eq("success")
      expect(dependency).not_to be_dependency_succeeded
      expect(dependent.failed_dependencies_for_execution).to contain_exactly(dependency)
    end

    it "treats closed-mode dependencies as satisfied when the target Job is cancelled" do
      prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 10, state: "closed", closure_reason: "cancelled")
      dependent = Factories.job_record(user: user, repository: repository, issue_number: 11, state: "queued")

      dependency = described_class.create!(
        job: dependent,
        depends_on_job: prerequisite,
        source: "manual",
        satisfaction_mode: "closed"
      )

      expect(dependency).to be_dependency_succeeded
      expect(dependency).to be_execution_dependency_satisfied
      expect(dependent.unsatisfied_dependencies).to be_empty
      expect(dependent.failed_dependencies_for_execution).to be_empty
    end

    it "keeps closed-mode dependencies blocked while the target Job is still open" do
      prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 10, state: "queued")
      dependent = Factories.job_record(user: user, repository: repository, issue_number: 11, state: "queued")

      dependency = described_class.create!(
        job: dependent,
        depends_on_job: prerequisite,
        source: "manual",
        satisfaction_mode: "closed"
      )

      expect(dependency).not_to be_dependency_succeeded
      expect(dependency).not_to be_execution_dependency_satisfied
      expect(dependent.unsatisfied_dependencies).to contain_exactly(dependency)
      expect(dependent.failed_dependencies_for_execution).to be_empty
    end

    it "treats an approved dependency in the same Epic as satisfied" do
      epic = Factories.epic(user: user, repository: repository)
      prerequisite = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 10, state: "approved")
      dependent = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 11, state: "queued")

      dependency = described_class.create!(job: dependent, depends_on_job: prerequisite, source: "manual")

      expect(dependency).to be_dependency_succeeded
    end

    it "treats a landing dependency in the same Epic as satisfied" do
      epic = Factories.epic(user: user, repository: repository)
      prerequisite = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 10, state: "landing")
      dependent = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 11, state: "queued")

      dependency = described_class.create!(job: dependent, depends_on_job: prerequisite, source: "manual")

      expect(dependency).to be_dependency_succeeded
    end

    it "does not treat an approved dependency from a different Epic as satisfied" do
      upstream_epic = Factories.epic(user: user, repository: repository)
      dependent_epic = Factories.epic(user: user, repository: repository)
      prerequisite = Factories.job_record(user: user, repository: repository, epic: upstream_epic, issue_number: 10, state: "approved")
      dependent = Factories.job_record(user: user, repository: repository, epic: dependent_epic, issue_number: 11, state: "queued")

      dependency = described_class.create!(job: dependent, depends_on_job: prerequisite, source: "manual")

      expect(dependency).not_to be_dependency_succeeded
    end
  end

  describe "linear chain enforcement within an epic" do
    let(:epic) { Factories.epic(user: user, repository: repository) }

    def epic_job(number)
      Factories.job_record(user: user, repository: repository, epic: epic, issue_number: number, state: "queued")
    end

    it "accepts a linear chain (each job depends on the previous one)" do
      a = epic_job(1)
      b = epic_job(2)
      c = epic_job(3)
      described_class.create!(job: b, depends_on_job: a, source: "manual")
      dep = described_class.new(job: c, depends_on_job: b, source: "manual")

      expect(dep).to be_valid
    end

    it "rejects a fork (upstream job already has a downstream in the same epic)" do
      a = epic_job(1)
      b = epic_job(2)
      c = epic_job(3)
      described_class.create!(job: b, depends_on_job: a, source: "manual")

      dep = described_class.new(job: c, depends_on_job: a, source: "manual")

      expect(dep).not_to be_valid
      expect(dep.errors[:base].first).to match(/Epic dependencies must form a single chain/)
    end

    it "rejects a merge (job already has an upstream in the same epic)" do
      a = epic_job(1)
      b = epic_job(2)
      c = epic_job(3)
      described_class.create!(job: c, depends_on_job: a, source: "manual")

      dep = described_class.new(job: c, depends_on_job: b, source: "manual")

      expect(dep).not_to be_valid
      expect(dep.errors[:base].first).to match(/Epic dependencies must form a single chain/)
    end

    it "rejects a new job with no dependency on the chain tail when non-first" do
      a = epic_job(1)
      b = epic_job(2)
      c = epic_job(3)
      described_class.create!(job: b, depends_on_job: a, source: "manual")

      # C tries to connect to A (not the chain tail B) — fork from A
      dep = described_class.new(job: c, depends_on_job: a, source: "manual")

      expect(dep).not_to be_valid
      expect(dep.errors[:base].first).to match(/Epic dependencies must form a single chain/)
    end

    it "enforces linearity in both simple and advanced instance mode" do
      a = epic_job(1)
      b = epic_job(2)
      c = epic_job(3)
      described_class.create!(job: b, depends_on_job: a, source: "manual")

      allow(AppSetting).to receive(:simple?).and_return(true)
      expect(described_class.new(job: c, depends_on_job: a, source: "manual")).not_to be_valid

      allow(AppSetting).to receive(:simple?).and_return(false)
      expect(described_class.new(job: c, depends_on_job: a, source: "manual")).not_to be_valid
    end

    it "does not enforce linearity for cross-epic dependencies" do
      other_epic = Factories.epic(user: user, repository: repository)
      a = Factories.job_record(user: user, repository: repository, epic: other_epic, issue_number: 10, state: "queued")
      b = epic_job(2)
      c = epic_job(3)
      described_class.create!(job: c, depends_on_job: b, source: "manual")

      # dep from b to a is cross-epic — no fork/merge enforcement
      dep = described_class.new(job: b, depends_on_job: a, source: "manual")

      expect(dep).to be_valid
    end

    it "does not enforce linearity for pending (unresolved) dependencies" do
      _a = epic_job(1)
      b = epic_job(2)
      described_class.create!(job: b, unresolved_owner: "acme", unresolved_repo: "x", unresolved_number: 99, source: "parsed")

      dep = described_class.new(job: b, unresolved_owner: "acme", unresolved_repo: "x", unresolved_number: 100, source: "parsed")
      # pending rows have no depends_on_job_id, so linearity check is skipped
      expect(dep.valid?).to be true
    end
  end

  describe "Epic dependency derivation" do
    it "creates a derived EpicDependency for cross-Epic Job dependencies" do
      upstream_epic = Factories.epic(user: user, repository: repository)
      dependent_epic = Factories.epic(user: user, repository: repository)
      upstream = Job.create!(user: user, repository: repository, issue_number: 100, epic: upstream_epic)
      dependent = Job.create!(user: user, repository: repository, issue_number: 101, epic: dependent_epic)

      expect {
        described_class.create!(job: dependent, depends_on_job: upstream, source: "manual")
      }.to change(EpicDependency, :count).by(1)

      edge = EpicDependency.last
      expect(edge).to have_attributes(
        epic: dependent_epic,
        depends_on_epic: upstream_epic,
        derived: true
      )
    end

    it "does not derive an EpicDependency inside the same Epic" do
      epic = Factories.epic(user: user, repository: repository)
      upstream = Job.create!(user: user, repository: repository, issue_number: 110, epic: epic)
      dependent = Job.create!(user: user, repository: repository, issue_number: 111, epic: epic)

      expect {
        described_class.create!(job: dependent, depends_on_job: upstream, source: "manual")
      }.not_to change(EpicDependency, :count)
    end

    it "derives the EpicDependency when a pending JobDependency resolves" do
      upstream_epic = Factories.epic(user: user, repository: repository)
      dependent_epic = Factories.epic(user: user, repository: repository)
      upstream = Job.create!(user: user, repository: repository, issue_number: 120, epic: upstream_epic)
      dependent = Job.create!(user: user, repository: repository, issue_number: 121, epic: dependent_epic)
      dependency = described_class.create!(job: dependent,
                                           unresolved_owner: repository.owner,
                                           unresolved_repo: repository.name,
                                           unresolved_number: upstream.issue_number,
                                           source: "parsed")

      expect {
        dependency.resolve!(depends_on_job: upstream)
      }.to change(EpicDependency, :count).by(1)
    end
  end
end
