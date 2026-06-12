require "rails_helper"

# Per-chip smoke tests. The Compiler is exercised via the public
# Filters::Compiler.call entry — these specs lean on it rather than
# instantiating chip classes directly so the AST round-trip is part
# of the coverage.
RSpec.describe "Filters::Chips" do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def run(field:, op:, value:)
    # Scope to the test's user so leakage from prior specs in the same
    # suite (or before(:context) seeds for unrelated users) doesn't
    # pollute results. The Repository chip still sees multiple repos
    # within the user's scope.
    Filters::Compiler.call(
      Filters::Ast.parse("field" => field, "op" => op, "value" => value),
      scope: Job.where(user: user),
      user: user
    )
  end

  describe "state" do
    it "filters by exact state" do
      queued_job = Factories.job(repository: repo, issue_number: 1)
      closed_job = Factories.job(repository: repo, issue_number: 2)
      closed_job.close!; closed_job.save!

      expect(run(field: "state", op: "is", value: queued_job.state)).to contain_exactly(queued_job)
    end

    it "supports is_one_of for multi-value matches" do
      queued_job = Factories.job(repository: repo, issue_number: 1)
      closed_job = Factories.job(repository: repo, issue_number: 2)
      closed_job.close!; closed_job.save!

      expect(run(field: "state", op: "is_one_of", value: [ queued_job.state, "closed" ])).to contain_exactly(queued_job, closed_job)
    end
  end

  describe "repository_id" do
    it "filters to one repository" do
      api = Factories.repository(user: user, owner: "acme", name: "api")
      mine = Factories.job(repository: repo, issue_number: 1)
      Factories.job(repository: api, issue_number: 2)

      expect(run(field: "repository_id", op: "is", value: repo.id)).to contain_exactly(mine)
    end
  end

  describe "pr_present" do
    it "matches jobs with a PR when op is is_true" do
      with_pr = Factories.job(repository: repo, issue_number: 1, pr_number: 42)
      Factories.job(repository: repo, issue_number: 2)

      expect(run(field: "pr_present", op: "is_true", value: nil)).to contain_exactly(with_pr)
    end

    it "matches jobs without a PR when op is is_false" do
      Factories.job(repository: repo, issue_number: 1, pr_number: 42)
      without = Factories.job(repository: repo, issue_number: 2)

      expect(run(field: "pr_present", op: "is_false", value: nil)).to contain_exactly(without)
    end
  end

  describe "age" do
    it "filters by created_at within the named window" do
      fresh = Factories.job(repository: repo, issue_number: 1)
      old = Factories.job(repository: repo, issue_number: 2)
      old.update!(created_at: 30.days.ago)

      expect(run(field: "age", op: "is", value: "1d")).to contain_exactly(fresh)
    end
  end

  describe "tags" do
    let(:bug) { Factories.tag(user: user, name: "bug") }
    let(:epic) { Factories.tag(user: user, name: "epic") }

    it "contains_any returns jobs with at least one of the tags" do
      tagged = Factories.job(repository: repo, issue_number: 1)
      tagged.tags << bug
      Factories.job(repository: repo, issue_number: 2)

      expect(run(field: "tags", op: "contains_any", value: [ bug.id ])).to contain_exactly(tagged)
    end

    it "contains_all only matches jobs with every listed tag" do
      both = Factories.job(repository: repo, issue_number: 1)
      both.tags << bug
      both.tags << epic
      one = Factories.job(repository: repo, issue_number: 2)
      one.tags << bug

      expect(run(field: "tags", op: "contains_all", value: [ bug.id, epic.id ])).to contain_exactly(both)
    end

    it "contains_none excludes jobs that have any of the listed tags" do
      tagged = Factories.job(repository: repo, issue_number: 1)
      tagged.tags << bug
      untagged = Factories.job(repository: repo, issue_number: 2)

      expect(run(field: "tags", op: "contains_none", value: [ bug.id ])).to contain_exactly(untagged)
    end
  end

  describe "attention preset" do
    it "pinned: returns only jobs pinned by the operator" do
      pinned = Factories.job(repository: repo, issue_number: 1)
      Factories.job(repository: repo, issue_number: 2)
      Factories.job_pin(user: user, job: pinned)

      expect(run(field: "attention", op: "is", value: "pinned")).to contain_exactly(pinned)
    end

    it "in_progress: includes running work but excludes queued workflows" do
      running = Factories.job_record(repository: repo, issue_number: 1, state: "running")
      landing_running = Factories.job_record(repository: repo, issue_number: 2, state: "landing")
      queued_rebase = Factories.job_record(repository: repo, issue_number: 3, state: "approved")
      running_rebase = Factories.job_record(repository: repo, issue_number: 4, state: "approved")
      finished_rebase = Factories.job_record(repository: repo, issue_number: 5, state: "approved")
      landing_queued = Factories.job_record(repository: repo, issue_number: 6, state: "landing")
      Factories.job_record(repository: repo, issue_number: 7, state: "approved")

      Workflow.create!(job: queued_rebase, trigger_kind: "rebase", state: "queued")
      Workflow.create!(job: running_rebase, trigger_kind: "rebase", state: "running")
      Workflow.create!(job: finished_rebase, trigger_kind: "rebase", state: "succeeded")
      Workflow.create!(job: landing_running, trigger_kind: "auto_merge", state: "running")
      Workflow.create!(job: landing_queued, trigger_kind: "auto_merge", state: "queued")

      expect(run(field: "attention", op: "is", value: "in_progress")).to contain_exactly(
        running,
        landing_running,
        running_rebase
      )
    end

    it "queued: returns queued jobs and jobs whose latest workflow is queued" do
      queued = Factories.job_record(repository: repo, issue_number: 21, state: "queued")
      queued_rebase = Factories.job_record(repository: repo, issue_number: 22, state: "approved")
      queued_landing = Factories.job_record(repository: repo, issue_number: 23, state: "landing")
      Factories.job_record(repository: repo, issue_number: 24, state: "approved")
      running_rebase = Factories.job_record(repository: repo, issue_number: 25, state: "approved")
      superseded_queue = Factories.job_record(repository: repo, issue_number: 26, state: "approved")

      Workflow.create!(job: queued_rebase, trigger_kind: "rebase", state: "queued")
      Workflow.create!(job: queued_landing, trigger_kind: "auto_merge", state: "queued")
      Workflow.create!(job: running_rebase, trigger_kind: "rebase", state: "running")
      Workflow.create!(job: superseded_queue, trigger_kind: "rebase", state: "queued")
      Workflow.create!(job: superseded_queue, trigger_kind: "rebase", state: "running")

      expect(run(field: "attention", op: "is", value: "queued")).to contain_exactly(
        queued,
        queued_rebase,
        queued_landing
      )
    end

    it "inbox: returns only actionable review, repair, and idle feedback jobs" do
      failed = Factories.job_record(repository: repo, issue_number: 11, state: "failed")
      implemented = Factories.job_record(repository: repo, issue_number: 12, state: "implemented")
      invalid = Factories.job_record(repository: repo, issue_number: 13, state: "triaging", validity: "duplicate")
      unread_feedback = Factories.job_record(
        repository: repo,
        issue_number: 14,
        state: "approved",
        last_seen_comment_at: 5.minutes.ago,
        last_feedback_addressed_at: 10.minutes.ago
      )
      Factories.job_record(repository: repo, issue_number: 15, state: "queued")
      Factories.job_record(
        repository: repo,
        issue_number: 16,
        state: "running",
        last_seen_comment_at: 5.minutes.ago,
        last_feedback_addressed_at: 10.minutes.ago
      )
      Factories.job_record(repository: repo, issue_number: 17, state: "triaging", triaging_reason: "pending_epic_ref")

      expect(run(field: "attention", op: "is", value: "inbox")).to contain_exactly(
        failed,
        implemented,
        invalid,
        unread_feedback
      )
    end

    it "awaiting_approval: excludes jobs with active PR feedback workflows" do
      ready = Factories.job_record(repository: repo, issue_number: 31, state: "implemented")
      queued_feedback = Factories.job_record(repository: repo, issue_number: 32, state: "implemented")
      running_feedback = Factories.job_record(repository: repo, issue_number: 33, state: "implemented")
      completed_feedback = Factories.job_record(repository: repo, issue_number: 34, state: "implemented")

      Workflow.create!(job: queued_feedback, trigger_kind: "pr_comment", state: "queued")
      Workflow.create!(job: running_feedback, trigger_kind: "pr_comment", state: "running")
      Workflow.create!(job: completed_feedback, trigger_kind: "pr_comment", state: "succeeded")

      expect(run(field: "attention", op: "is", value: "awaiting_approval")).to contain_exactly(
        ready,
        completed_feedback
      )
    end

    it "just_failed: returns jobs in :failed state" do
      failed = Factories.job(repository: repo, issue_number: 1)
      failed.update!(state: "failed")
      Factories.job(repository: repo, issue_number: 2)

      expect(run(field: "attention", op: "is", value: "just_failed")).to contain_exactly(failed)
    end

    it "merged_this_week: returns recently-merged closed threads" do
      merged = Factories.job(repository: repo, issue_number: 1)
      merged.update!(state: "closed", closure_reason: "pr_merged", finished_at: 2.days.ago)
      Factories.job(repository: repo, issue_number: 2)

      expect(run(field: "attention", op: "is", value: "merged_this_week")).to contain_exactly(merged)
    end
  end
end
