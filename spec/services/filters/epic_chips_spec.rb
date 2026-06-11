require "rails_helper"

RSpec.describe "Filters::Chips::Epics" do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def run(field:, op:, value: nil)
    Filters::Compiler.call(
      Filters::Ast.parse("field" => field, "op" => op, "value" => value),
      scope: Epic.where(user: user),
      user: user,
      subject: :epic
    )
  end

  def child_job(epic, **attrs)
    issue_number = attrs.delete(:issue_number) || SecureRandom.random_number(10_000) + 1
    Factories.job(repository: repo, epic: epic, issue_number: issue_number, **attrs)
  end

  describe "subject registration" do
    it "registers the Epic subject and chip map" do
      subject = Filters::SUBJECTS[:epic]

      expect(subject.model).to eq(Epic)
      expect(subject.chips).to include(
        "state" => "Filters::Chips::Epics::State",
        "has_child_jobs" => "Filters::Chips::Epics::HasChildJobs",
        "attention" => "Filters::Chips::Epics::Attention"
      )
    end

    it "serializes an Epic schema for the chip bar" do
      schema = Filters::Schema.for(subject: :epic, user: user)
      by_field = schema.index_by { |chip| chip["field"] }

      expect(by_field["state"]["values"].map { |v| v["value"] }).to eq(Epic::STATES)
      expect(by_field["attention"]["values"].map { |v| v["value"] }).to include("ready_to_start", "stalled")
      expect(by_field["child_job_count"]["bucket"]).to eq("number")
    end
  end

  describe "state" do
    it "filters by Epic state" do
      ready = Factories.epic(user: user, repository: repo, state: "ready")
      Factories.epic(user: user, repository: repo, state: "backlog")

      expect(run(field: "state", op: "is", value: "ready")).to contain_exactly(ready)
    end
  end

  describe "title" do
    it "filters by title text" do
      match = Factories.epic(user: user, repository: repo, title: "Ship filters")
      Factories.epic(user: user, repository: repo, title: "Polish buttons")

      expect(run(field: "title", op: "contains", value: "filters")).to contain_exactly(match)
    end
  end

  describe "description" do
    it "filters by description text" do
      match = Factories.epic(user: user, repository: repo, description: "child jobs need chips")
      Factories.epic(user: user, repository: repo, description: "unrelated")

      expect(run(field: "description", op: "contains", value: "chips")).to contain_exactly(match)
    end
  end

  describe "done_at" do
    it "filters by completion time" do
      recent = Factories.epic(user: user, repository: repo, state: "done", done_at: 2.days.ago)
      Factories.epic(user: user, repository: repo, state: "done", done_at: 20.days.ago)

      expect(run(field: "done_at", op: "within_last", value: { "n" => 7, "unit" => "days" })).to contain_exactly(recent)
    end
  end

  describe "number" do
    it "filters by Epic number" do
      low = Factories.epic(user: user, repository: repo)
      high = Factories.epic(user: user, repository: repo)

      expect(run(field: "number", op: "greater_than", value: low.number)).to contain_exactly(high)
    end
  end

  describe "auto_approve_mode" do
    it "filters by auto-approve mode" do
      match = Factories.epic(user: user, repository: repo, auto_approve_mode: "if_graders_pass")
      Factories.epic(user: user, repository: repo, auto_approve_mode: "never")

      expect(run(field: "auto_approve_mode", op: "is", value: "if_graders_pass")).to contain_exactly(match)
    end
  end

  describe "has_child_jobs" do
    it "matches Epics with child Jobs" do
      parent = Factories.epic(user: user, repository: repo)
      child_job(parent)
      Factories.epic(user: user, repository: repo)

      expect(run(field: "has_child_jobs", op: "is_true")).to contain_exactly(parent)
    end
  end

  describe "has_open_children" do
    it "matches Epics with open child Jobs" do
      parent = Factories.epic(user: user, repository: repo)
      child_job(parent).update!(state: "queued")
      closed_parent = Factories.epic(user: user, repository: repo)
      child_job(closed_parent).update!(state: "closed", closure_reason: "pr_merged")

      expect(run(field: "has_open_children", op: "is_true")).to contain_exactly(parent)
    end
  end

  describe "has_blocked_children" do
    it "matches Epics with child Jobs that have unsatisfied dependencies" do
      parent = Factories.epic(user: user, repository: repo)
      blocked = child_job(parent)
      JobDependency.create!(
        job: blocked,
        source: "manual",
        unresolved_owner: repo.owner,
        unresolved_repo: repo.name,
        unresolved_number: 999
      )
      Factories.epic(user: user, repository: repo)

      expect(run(field: "has_blocked_children", op: "is_true")).to contain_exactly(parent)
    end
  end

  describe "child_job_count" do
    it "filters by child Job count" do
      parent = Factories.epic(user: user, repository: repo)
      2.times { child_job(parent) }
      one_child = Factories.epic(user: user, repository: repo)
      child_job(one_child)

      expect(run(field: "child_job_count", op: "greater_than", value: 1)).to contain_exactly(parent)
    end
  end

  describe "child_progress_percent" do
    it "filters by percent of merged child Jobs" do
      complete = Factories.epic(user: user, repository: repo)
      child_job(complete).update!(state: "closed", closure_reason: "pr_merged")
      child_job(complete).update!(state: "closed", closure_reason: "external_pr_merged")
      partial = Factories.epic(user: user, repository: repo)
      child_job(partial).update!(state: "closed", closure_reason: "pr_merged")
      child_job(partial)

      expect(run(field: "child_progress_percent", op: "equals", value: 100)).to contain_exactly(complete)
    end
  end

  describe "has_epic_dependency" do
    it "matches Epics with unfinished Epic dependencies" do
      blocked = Factories.epic(user: user, repository: repo)
      upstream = Factories.epic(user: user, repository: repo, state: "in_progress")
      EpicDependency.create!(epic: blocked, depends_on_epic: upstream)
      Factories.epic(user: user, repository: repo)

      expect(run(field: "has_epic_dependency", op: "is_true")).to contain_exactly(blocked)
    end
  end

  describe "attention presets" do
    it "ready_to_start: returns ready Epics" do
      ready = Factories.epic(user: user, repository: repo, state: "ready")
      Factories.epic(user: user, repository: repo, state: "backlog")

      expect(run(field: "attention", op: "is", value: "ready_to_start")).to contain_exactly(ready)
    end

    it "in_progress: returns in-progress Epics" do
      active = Factories.epic(user: user, repository: repo, state: "in_progress")
      Factories.epic(user: user, repository: repo, state: "ready")

      expect(run(field: "attention", op: "is", value: "in_progress")).to contain_exactly(active)
    end

    it "stalled: returns in-progress Epics without child Run activity in the last week" do
      stalled = Factories.epic(user: user, repository: repo, state: "in_progress")
      child_job(stalled).runs.update_all(updated_at: 8.days.ago)
      active = Factories.epic(user: user, repository: repo, state: "in_progress")
      child_job(active)

      expect(run(field: "attention", op: "is", value: "stalled")).to contain_exactly(stalled)
    end

    it "empty: returns Epics with no child Jobs" do
      empty = Factories.epic(user: user, repository: repo)
      parent = Factories.epic(user: user, repository: repo)
      child_job(parent)

      expect(run(field: "attention", op: "is", value: "empty")).to contain_exactly(empty)
    end

    it "blocked_by_dependency: returns Epics with unfinished Epic dependencies" do
      blocked = Factories.epic(user: user, repository: repo)
      upstream = Factories.epic(user: user, repository: repo, state: "ready")
      EpicDependency.create!(epic: blocked, depends_on_epic: upstream)
      Factories.epic(user: user, repository: repo)

      expect(run(field: "attention", op: "is", value: "blocked_by_dependency")).to contain_exactly(blocked)
    end

    it "recently_done: returns Epics completed in the last week" do
      recent = Factories.epic(user: user, repository: repo, state: "done", done_at: 2.days.ago)
      Factories.epic(user: user, repository: repo, state: "done", done_at: 12.days.ago)

      expect(run(field: "attention", op: "is", value: "recently_done")).to contain_exactly(recent)
    end
  end
end
