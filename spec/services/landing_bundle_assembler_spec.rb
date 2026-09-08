require "rails_helper"

RSpec.describe LandingBundleAssembler do
  describe ".for_repository (priority-tier scope, formerly JobBundleAssembler)" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user, auto_merge_enabled: true) }

    def approved(issue_number:, priority: "medium", pr_number: nil, parent_job: nil, kind: "issue", owner_user: user)
      Factories.job_record(
        user: user,
        owner_user: owner_user,
        repository: repository,
        issue_number: issue_number,
        state: "approved",
        priority: priority,
        pr_number: pr_number || (1000 + issue_number),
        parent_job: parent_job,
        kind: kind
      )
    end

    # external_pr Jobs must be created in :implemented state (validated on
    # create) and with a blank issue_number. Factories.job_record always
    # forces state to "closed" on create then update_columns, so use
    # Job.create! directly for this kind, same as landing_queue_processor_spec.
    def approved_external_pr(external_pr_number:, priority: "medium")
      Job.create!(
        user: user,
        owner_user: user,
        repository: repository,
        kind: "external_pr",
        issue_number: nil,
        external_pr_number: external_pr_number,
        priority: priority,
        state: "implemented"
      ).tap do |job|
        job.approve!(via: "operator")
      end
    end

    it "is not ready when fewer than 2 same-tier candidates exist" do
      approved(issue_number: 1)

      result = described_class.for_repository(repository)

      expect(result).not_to be_ready
      expect(result.reason).to match(/fewer than 2/)
    end

    it "is ready with 2 or more same-tier candidates" do
      a = approved(issue_number: 1)
      b = approved(issue_number: 2)

      result = described_class.for_repository(repository)

      expect(result).to be_ready
      expect(result.priority).to eq("medium")
      expect(result.job_ids).to contain_exactly(a.id, b.id)
    end

    it "does not mix priority tiers into one bundle" do
      approved(issue_number: 1, priority: "urgent")
      approved(issue_number: 2, priority: "medium")
      approved(issue_number: 3, priority: "medium")

      result = described_class.for_repository(repository)

      expect(result).to be_ready
      expect(result.priority).to eq("medium")
      expect(result.members.map(&:priority)).to all(eq("medium"))
    end

    it "prefers the urgent tier when it has enough candidates" do
      urgent_a = approved(issue_number: 1, priority: "urgent")
      urgent_b = approved(issue_number: 2, priority: "urgent")
      approved(issue_number: 3, priority: "medium")
      approved(issue_number: 4, priority: "medium")

      result = described_class.for_repository(repository)

      expect(result.priority).to eq("urgent")
      expect(result.job_ids).to contain_exactly(urgent_a.id, urgent_b.id)
    end

    it "does not query lower-priority tiers once a higher tier is ready (partitions stays lazy)" do
      approved(issue_number: 1, priority: "urgent")
      approved(issue_number: 2, priority: "urgent")
      approved(issue_number: 3, priority: "medium")
      approved(issue_number: 4, priority: "medium")

      scope = LandingBundleAssembler::Scopes::PriorityTier.new(repository)
      allow(LandingBundleAssembler::Scopes::PriorityTier).to receive(:new).with(repository).and_return(scope)
      original_eligible_candidates = scope.method(:eligible_candidates)
      queried_priorities = []
      allow(scope).to receive(:eligible_candidates) do |priority|
        queried_priorities << priority
        original_eligible_candidates.call(priority)
      end

      result = described_class.for_repository(repository)

      expect(result).to be_ready
      expect(result.priority).to eq("urgent")
      expect(queried_priorities).to eq([ "urgent" ])
    end

    it "does not bundle same-tier Jobs from different owners together" do
      other_owner = Factories.user
      approved(issue_number: 1, owner_user: user)
      approved(issue_number: 2, owner_user: other_owner)

      result = described_class.for_repository(repository)

      expect(result).not_to be_ready
    end

    it "still bundles same-tier Jobs that share one owner" do
      a = approved(issue_number: 1, owner_user: user)
      b = approved(issue_number: 2, owner_user: user)

      result = described_class.for_repository(repository)

      expect(result).to be_ready
      expect(result.job_ids).to contain_exactly(a.id, b.id)
    end

    it "excludes an epicless candidate whose prerequisite is outside the bundle and unmerged" do
      epic = Factories.epic(user: user, repository: repository)
      epic_child = Factories.job_record(
        user: user,
        owner_user: user,
        repository: repository,
        epic: epic,
        issue_number: 10,
        state: "landing",
        pr_number: 1010
      )
      blocked = approved(issue_number: 1, parent_job: epic_child)
      JobDependency.create!(job: blocked, depends_on_job: epic_child, source: "manual")
      ready = approved(issue_number: 2)
      sibling = approved(issue_number: 3)

      expect(described_class.ready_for_job?(blocked)).to be false
      expect(described_class.ready_for_job?(ready)).to be true
      expect(described_class.for_repository(repository).job_ids).to contain_exactly(ready.id, sibling.id)
    end

    it "allows prerequisite chains that are fully contained in the bundle" do
      parent = approved(issue_number: 1)
      child = approved(issue_number: 2, parent_job: parent)
      JobDependency.create!(job: child, depends_on_job: parent, source: "manual")

      result = described_class.for_repository(repository)

      expect(result).to be_ready
      expect(result.job_ids).to eq([ parent.id, child.id ])
    end

    it "bundles the owner-partition that reaches the minimum, ignoring a lone Job from another owner" do
      other_owner = Factories.user
      a = approved(issue_number: 1, owner_user: user)
      b = approved(issue_number: 2, owner_user: user)
      approved(issue_number: 3, owner_user: other_owner)

      result = described_class.for_repository(repository)

      expect(result).to be_ready
      expect(result.job_ids).to contain_exactly(a.id, b.id)
    end

    it "excludes Jobs that belong to an Epic" do
      epic = Factories.epic(user: user, repository: repository)
      Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 1, state: "approved", pr_number: 900)
      approved(issue_number: 2)

      result = described_class.for_repository(repository)

      expect(result).not_to be_ready
    end

    it "excludes external-PR Jobs (they land via Workflows::ExternalPrMerge, not their own PR)" do
      approved_external_pr(external_pr_number: 1)
      approved(issue_number: 2)

      result = described_class.for_repository(repository)

      expect(result).not_to be_ready
    end

    it "excludes Jobs from other repositories" do
      other_repo = Factories.repository(user: user, auto_merge_enabled: true)
      approved(issue_number: 1)
      Factories.job_record(user: user, repository: other_repo, issue_number: 2, state: "approved", pr_number: 2002)

      result = described_class.for_repository(repository)

      expect(result).not_to be_ready
    end

    it "excludes Jobs that are not approved" do
      approved(issue_number: 1)
      Factories.job_record(user: user, repository: repository, issue_number: 2, state: "implemented", pr_number: 1002)

      result = described_class.for_repository(repository)

      expect(result).not_to be_ready
    end

    it "orders members topologically (a prerequisite before its dependent)" do
      parent_placeholder = approved(issue_number: 1)
      dependent = approved(issue_number: 2, parent_job: parent_placeholder)

      result = described_class.for_repository(repository)

      expect(result).to be_ready
      expect(result.job_ids).to eq([ parent_placeholder.id, dependent.id ])
    end

    it "caps bundle size at AppSetting.merge_train_max_size" do
      AppSetting.current.update!(merge_train_max_size: 2)
      a = approved(issue_number: 1)
      b = approved(issue_number: 2)
      approved(issue_number: 3)

      result = described_class.for_repository(repository)

      expect(result).to be_ready
      expect(result.job_ids).to eq([ a.id, b.id ])
    end

    it "shrinks the cap rather than splitting a dependency-linked pair across bundles" do
      AppSetting.current.update!(merge_train_max_size: 3)
      a = approved(issue_number: 1)
      b = approved(issue_number: 2)
      c = approved(issue_number: 3)
      d = approved(issue_number: 4)
      JobDependency.create!(job: d, depends_on_job: c, source: "manual")

      result = described_class.for_repository(repository)

      expect(result).to be_ready
      expect(result.job_ids).to eq([ a.id, b.id ])
    end

    it "is not ready when capping to respect a dependency edge drops below the minimum" do
      AppSetting.current.update!(merge_train_max_size: 2)
      a = approved(issue_number: 1)
      b = approved(issue_number: 2)
      c = approved(issue_number: 3)
      JobDependency.create!(job: c, depends_on_job: b, source: "manual")

      result = described_class.for_repository(repository)

      expect(result).not_to be_ready
    end

    describe ".ready_for_priority?" do
      it "agrees with .for_repository when the tier's candidates fit under the cap" do
        approved(issue_number: 1)
        approved(issue_number: 2)

        expect(described_class.ready_for_priority?(repository, "medium")).to be true
      end

      it "agrees with .for_repository when dependency-edge capping drops the tier below the minimum" do
        AppSetting.current.update!(merge_train_max_size: 2)
        approved(issue_number: 1)
        b = approved(issue_number: 2)
        c = approved(issue_number: 3)
        JobDependency.create!(job: c, depends_on_job: b, source: "manual")

        expect(described_class.ready_for_priority?(repository, "medium")).to be false
      end

      it "returns false when same-tier candidates exist but belong to different owners" do
        other_owner = Factories.user
        approved(issue_number: 1, owner_user: user)
        approved(issue_number: 2, owner_user: other_owner)

        expect(described_class.ready_for_priority?(repository, "medium")).to be false
      end
    end

    describe ".ready_for_job?" do
      it "is true when the Job's own owner-partition is ready" do
        a = approved(issue_number: 1, owner_user: user)
        approved(issue_number: 2, owner_user: user)

        expect(described_class.ready_for_job?(a)).to be true
      end

      it "is false for a solo owner even while a different owner's same-tier bundle is ready" do
        other_owner = Factories.user
        solo = approved(issue_number: 1, owner_user: user)
        approved(issue_number: 2, owner_user: other_owner)
        approved(issue_number: 3, owner_user: other_owner)

        expect(described_class.ready_for_job?(solo)).to be false
      end

      it "is true for a member of the ready bundle even while a solo different-owner Job exists in the same tier" do
        other_owner = Factories.user
        approved(issue_number: 1, owner_user: other_owner)
        b = approved(issue_number: 2, owner_user: user)
        approved(issue_number: 3, owner_user: user)

        expect(described_class.ready_for_job?(b)).to be true
      end

      it "is false for an Epic-backed Job" do
        epic = Factories.epic(user: user, repository: repository)
        member = Factories.job_record(user: user, owner_user: user, repository: repository, epic: epic, issue_number: 1, state: "approved", pr_number: 900)
        approved(issue_number: 2, owner_user: user)

        expect(described_class.ready_for_job?(member)).to be false
      end

      it "is false for an external_pr Job" do
        external = approved_external_pr(external_pr_number: 1)
        approved(issue_number: 2, owner_user: user)

        expect(described_class.ready_for_job?(external)).to be false
      end
    end
  end

  describe ".for_epic (epic-backed scope, formerly MergeTrainAssembler)" do
    let(:user) { Factories.user }
    let(:repository) { Factories.repository(user: user, auto_merge_enabled: true) }
    let(:epic) { Factories.epic(user: user, repository: repository) }

    def child(issue_number:, state: "approved", pr_number: nil, parent_job: nil)
      Factories.job_record(
        user: user,
        repository: repository,
        epic: epic,
        issue_number: issue_number,
        state: state,
        pr_number: pr_number || (1000 + issue_number),
        parent_job: parent_job
      )
    end

    # The landing prefetcher used to reach here with nil for a unit that mixed
    # one Epic child with epicless Jobs, and the NoMethodError took down the
    # whole landing attempt -- 13 bundle trains in one day. "No Epic" is a
    # not-ready answer, not an exception.
    it "reports not ready rather than raising when there is no Epic" do
      result = described_class.for_epic(nil)

      expect(result).not_to be_ready
      expect(result.reason).to match(/no Epic/i)
      expect(result.members).to be_empty
    end

    it "is ready when every open child is approved and has a PR" do
      a = child(issue_number: 1)
      b = child(issue_number: 2)

      result = described_class.for_epic(epic)

      expect(result).to be_ready
      expect(result.job_ids).to contain_exactly(a.id, b.id)
    end

    it "orders members topologically (a prerequisite before its dependent)" do
      # Create the dependent first (lower id) so only dependency ordering
      # can put the parent ahead of it.
      parent_placeholder = child(issue_number: 1)
      dependent = child(issue_number: 2, parent_job: parent_placeholder)

      result = described_class.for_epic(epic)

      expect(result).to be_ready
      expect(result.job_ids).to eq([ parent_placeholder.id, dependent.id ])
    end

    it "includes every leaf in an explicit nonlinear fan-in Epic" do
      root = child(issue_number: 1)
      leaf_a = child(issue_number: 2, parent_job: root)
      leaf_b = child(issue_number: 3, parent_job: root)

      result = described_class.for_epic(epic)

      expect(result).to be_ready
      expect(result.job_ids).to eq([ root.id, leaf_a.id, leaf_b.id ])
    end

    it "is not ready when any open child is unapproved" do
      child(issue_number: 1, state: "approved")
      child(issue_number: 2, state: "implemented")

      result = described_class.for_epic(epic)

      expect(result).not_to be_ready
      expect(result.reason).to match(/not yet approved/)
    end

    it "is not ready when a child has no PR" do
      child(issue_number: 1, state: "approved", pr_number: nil)
      Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 2, state: "approved", pr_number: nil)

      # Override one to truly have no PR.
      epic.jobs.first.update_columns(pr_number: nil)

      result = described_class.for_epic(epic)

      expect(result).not_to be_ready
      expect(result.reason).to match(/without a PR/)
    end

    it "excludes already-merged children from the member set without blocking readiness" do
      a = child(issue_number: 1, state: "approved")
      merged = child(issue_number: 2, state: "closed")
      merged.update_columns(closure_reason: "pr_merged")

      result = described_class.for_epic(epic)

      expect(result).to be_ready
      expect(result.job_ids).to eq([ a.id ])
    end

    it "is not ready when there are no open children" do
      result = described_class.for_epic(epic)

      expect(result).not_to be_ready
      expect(result.reason).to match(/no open child/)
    end

    it "is not ready when the epic exceeds merge_train_max_size" do
      AppSetting.current.update!(merge_train_max_size: 1)
      child(issue_number: 1)
      child(issue_number: 2)

      result = described_class.for_epic(epic)

      expect(result).not_to be_ready
      expect(result.reason).to match(/merge_train_max_size/)
    end
  end
end
