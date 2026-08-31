require "rails_helper"

# Coverage for the chip types added on top of the original six. The
# Compiler is exercised via its public entry point so AST parsing
# is part of every test path.
RSpec.describe "Filters::Chips (new primitives)" do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def run(field:, op:, value:)
    Filters::Compiler.call(
      Filters::Ast.parse("field" => field, "op" => op, "value" => value),
      scope: Job.where(user: user),
      user: user
    )
  end

  describe "string chips (StringColumn base)" do
    it "title contains" do
      match = Factories.job_record(repository: repo, issue_number: 1, issue_title: "Restore the aqueduct")
      Factories.job_record(repository: repo, issue_number: 2, issue_title: "Build the forum")

      expect(run(field: "title", op: "contains", value: "aqueduct")).to contain_exactly(match)
    end

    it "title matches uses the documented full-text fallback" do
      match = Factories.job_record(repository: repo, issue_number: 1, issue_title: "Restore the aqueduct")
      Factories.job_record(repository: repo, issue_number: 2, issue_title: "Build the forum")

      expect(run(field: "title", op: "matches", value: "aqueduct")).to contain_exactly(match)
    end

    it "quotes the LIKE escape literal through the active adapter" do
      allow(Job.connection).to receive(:quote).and_call_original
      allow(Job.connection).to receive(:quote).with("\\").and_return("'\\\\'")

      sql = run(field: "title", op: "contains", value: "aqueduct").to_sql

      expect(sql).to include("ESCAPE '\\\\'")
    end

    it "treats LIKE wildcard characters as literal input" do
      literal = Factories.job_record(repository: repo, issue_number: 1, issue_title: "Fix 100% CLI")
      Factories.job_record(repository: repo, issue_number: 2, issue_title: "Fix 100x CLI")

      expect(run(field: "title", op: "contains", value: "100%")).to contain_exactly(literal)
    end

    it "title does_not_contain excludes matches" do
      excluded = Factories.job_record(repository: repo, issue_number: 1, issue_title: "Restore the aqueduct")
      kept = Factories.job_record(repository: repo, issue_number: 2, issue_title: "Build the forum")

      expect(run(field: "title", op: "does_not_contain", value: "aqueduct")).to contain_exactly(kept)
    end

    it "title starts_with" do
      match = Factories.job_record(repository: repo, issue_number: 1, issue_title: "Restore the aqueduct")
      Factories.job_record(repository: repo, issue_number: 2, issue_title: "Build the forum")

      expect(run(field: "title", op: "starts_with", value: "Restore")).to contain_exactly(match)
    end

    it "branch_name ends_with" do
      match = Factories.job_record(repository: repo, issue_number: 1, branch_name: "syrus/issue-1")
      Factories.job_record(repository: repo, issue_number: 2, branch_name: "feature/other")

      expect(run(field: "branch_name", op: "ends_with", value: "issue-1")).to contain_exactly(match)
    end

    it "title is_set matches only jobs with a non-blank title" do
      Factories.job_record(repository: repo, issue_number: 1, issue_title: "")
      with_title = Factories.job_record(repository: repo, issue_number: 2, issue_title: "Forum survey")

      expect(run(field: "title", op: "is_set", value: nil)).to contain_exactly(with_title)
    end
  end

  describe "number chips (NumberColumn base)" do
    it "issue_number equals" do
      match = Factories.job_record(repository: repo, issue_number: 42)
      Factories.job_record(repository: repo, issue_number: 7)

      expect(run(field: "issue_number", op: "equals", value: 42)).to contain_exactly(match)
    end

    it "issue_number between (inclusive range)" do
      lo = Factories.job_record(repository: repo, issue_number: 10)
      hi = Factories.job_record(repository: repo, issue_number: 20)
      Factories.job_record(repository: repo, issue_number: 21)

      expect(run(field: "issue_number", op: "between", value: [ 10, 20 ])).to contain_exactly(lo, hi)
    end

    it "pr_number is_unset matches jobs without a PR" do
      Factories.job_record(repository: repo, issue_number: 1, pr_number: 99)
      without = Factories.job_record(repository: repo, issue_number: 2)

      expect(run(field: "pr_number", op: "is_unset", value: nil)).to contain_exactly(without)
    end
  end

  describe "date chips (DateColumn base)" do
    it "created_at within_last matches recent jobs" do
      fresh = Factories.job_record(repository: repo, issue_number: 1)
      old = Factories.job_record(repository: repo, issue_number: 2)
      old.update!(created_at: 30.days.ago)

      result = run(field: "created_at", op: "within_last", value: { "n" => 1, "unit" => "days" })
      expect(result).to contain_exactly(fresh)
    end

    it "created_at more_than_ago is the inverse" do
      Factories.job_record(repository: repo, issue_number: 1)
      old = Factories.job_record(repository: repo, issue_number: 2)
      old.update!(created_at: 30.days.ago)

      result = run(field: "created_at", op: "more_than_ago", value: { "n" => 1, "unit" => "days" })
      expect(result).to contain_exactly(old)
    end

    it "finished_at is_set matches closed jobs only" do
      closed = Factories.job_record(repository: repo, issue_number: 1)
      closed.update!(state: "closed", finished_at: Time.current)
      Factories.job_record(repository: repo, issue_number: 2)

      expect(run(field: "finished_at", op: "is_set", value: nil)).to contain_exactly(closed)
    end
  end

  describe "enum-column chips (EnumColumn base)" do
    it "priority is" do
      high = Factories.job_record(repository: repo, issue_number: 1, priority: "high")
      Factories.job_record(repository: repo, issue_number: 2, priority: "medium")

      expect(run(field: "priority", op: "is", value: "high")).to contain_exactly(high)
    end

    it "agent_provider is_one_of" do
      claude = Factories.job_record(repository: repo, issue_number: 1, agent_provider: "claude")
      codex  = Factories.job_record(repository: repo, issue_number: 2, agent_provider: "codex")

      expect(run(field: "agent_provider", op: "is_one_of", value: %w[ claude codex ])).to contain_exactly(claude, codex)
    end

    it "closure_reason is_set distinguishes closed-with-reason from open jobs" do
      merged = Factories.job_record(repository: repo, issue_number: 1)
      merged.update!(state: "closed", closure_reason: "pr_merged", finished_at: Time.current)
      Factories.job_record(repository: repo, issue_number: 2)

      expect(run(field: "closure_reason", op: "is_set", value: nil)).to contain_exactly(merged)
    end
  end

  describe "FK chips (FkColumn base)" do
    it "parent_job_id is_set matches stacked children" do
      parent = Factories.job_record(repository: repo, issue_number: 100)
      child = Factories.job_record(repository: repo, issue_number: 1, parent_job_id: parent.id)
      Factories.job_record(repository: repo, issue_number: 2)

      expect(run(field: "parent_job_id", op: "is_set", value: nil)).to contain_exactly(child)
    end
  end

  describe "latest-X derivations" do
    it "latest_run_state is" do
      failed = Factories.job(repository: repo, issue_number: 1)
      failed.initial_run.update!(state: "failed", finished_at: Time.current)
      Factories.job(repository: repo, issue_number: 2)

      expect(run(field: "latest_run_state", op: "is", value: "failed")).to contain_exactly(failed)
    end

    it "latest_workflow_trigger_kind is_one_of" do
      job = Factories.job(repository: repo, issue_number: 1)
      Factories.job(repository: repo, issue_number: 2)

      # `Factories.job` triggers the initial workflow, so this job
      # matches "initial" by default.
      expect(run(field: "latest_workflow_trigger_kind", op: "is_one_of", value: %w[ initial retry ])).to include(job)
    end
  end

  describe "boolean predicates" do
    it "pinned_by_me is_true returns only the operator's pinned jobs" do
      pinned = Factories.job_record(repository: repo, issue_number: 1)
      Factories.job_record(repository: repo, issue_number: 2)
      Factories.job_pin(user: user, job: pinned)

      expect(run(field: "pinned_by_me", op: "is_true", value: nil)).to contain_exactly(pinned)
    end

    it "has_unread_feedback is_true uses the comment-watermark fields" do
      unread = Factories.job_record(repository: repo, issue_number: 1)
      unread.update!(last_seen_comment_at: 1.hour.ago, last_feedback_addressed_at: nil)
      addressed = Factories.job_record(repository: repo, issue_number: 2)
      addressed.update!(last_seen_comment_at: 1.hour.ago, last_feedback_addressed_at: 30.minutes.ago)
      Factories.job_record(repository: repo, issue_number: 3)

      expect(run(field: "has_unread_feedback", op: "is_true", value: nil)).to contain_exactly(unread)
    end

    it "has_parent_job is_true matches stacked children" do
      parent = Factories.job_record(repository: repo, issue_number: 100)
      child = Factories.job_record(repository: repo, issue_number: 1, parent_job_id: parent.id)
      Factories.job_record(repository: repo, issue_number: 2)

      expect(run(field: "has_parent_job", op: "is_true", value: nil)).to contain_exactly(child)
    end

    it "has_child_jobs is_true matches parents of stacks" do
      parent = Factories.job_record(repository: repo, issue_number: 100)
      Factories.job_record(repository: repo, issue_number: 1, parent_job_id: parent.id)
      Factories.job_record(repository: repo, issue_number: 2)

      expect(run(field: "has_child_jobs", op: "is_true", value: nil)).to contain_exactly(parent)
    end
  end
end
