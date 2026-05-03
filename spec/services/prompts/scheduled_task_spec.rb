require "rails_helper"

RSpec.describe Prompts::ScheduledTask do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:task) do
    ScheduledTask.create!(
      user: user, repository: repository,
      name: "Sweep dead code",
      prompt: "Look for dead code in `#{'{{repo_slug}}'}` and remove anything orphaned. Today is {{date}}.",
      kind: "cron", cron_expression: "0 9 * * 1", pr_pileup_policy: "skip"
    )
  end
  let(:fired_at) { Time.utc(2026, 5, 4, 9, 23, 0) }

  it "wraps the user prompt in a Syrus preamble that warns against making work" do
    output = described_class.new(scheduled_task: task, fired_at: fired_at).to_s
    expect(output).to include("scheduled maintenance task")
    expect(output).to match(/only commit changes if there's something\s+genuinely\s+worth changing/i)
    expect(output).to match(/run\s+`submit_summary`/)
    expect(output).to include(repository.slug)
  end

  it "appends the SubmitSummaryInstructions block" do
    output = described_class.new(scheduled_task: task, fired_at: fired_at).to_s
    expect(output).to include("submit_summary")
    expect(output).to include("pr_title")
  end

  it "interpolates supported template variables in the user prompt" do
    output = described_class.new(scheduled_task: task, fired_at: fired_at).to_s
    expect(output).to include("acme/widgets")
    expect(output).to include("Today is 2026-05-04")
  end

  it "leaves unknown variables literal" do
    task.update!(prompt: "{{not_a_real_var}} stays as-is.")
    output = described_class.new(scheduled_task: task, fired_at: fired_at).to_s
    expect(output).to include("{{not_a_real_var}}")
  end

  it "renders 'never' when last_fired_at is nil" do
    task.update!(prompt: "Last fire: {{last_fired_at}}.")
    output = described_class.new(scheduled_task: task, fired_at: fired_at).to_s
    expect(output).to include("Last fire: never.")
  end

  it "uses the iso8601 of last_fired_at when present" do
    last = Time.utc(2026, 4, 27, 9, 23, 0)
    task.update!(prompt: "Last fire: {{last_fired_at}}.", last_fired_at: last)
    output = described_class.new(scheduled_task: task, fired_at: fired_at).to_s
    expect(output).to include(last.iso8601)
  end

  describe "footer" do
    it "includes previous fire timestamp" do
      last = Time.utc(2026, 4, 27, 9, 0, 0)
      task.update!(last_fired_at: last)
      output = described_class.new(scheduled_task: task, fired_at: fired_at).to_s
      expect(output).to include("Previous fire: #{last.iso8601}")
    end

    it "shows 'never' for previous fire when the task has never fired" do
      output = described_class.new(scheduled_task: task, fired_at: fired_at).to_s
      expect(output).to include("Previous fire: never")
    end

    it "shows 'Last PR: none' when the task has no PR jobs" do
      output = described_class.new(scheduled_task: task, fired_at: fired_at).to_s
      expect(output).to include("Last PR: none")
    end

    it "shows the last PR number and 'open' state when the job is open" do
      task.jobs.create!(
        user: user, repository: repository,
        kind: "cron", scheduled_task: task, issue_number: nil, pr_number: 42
      )
      output = described_class.new(scheduled_task: task, fired_at: fired_at).to_s
      expect(output).to include("Last PR: #42 (open)")
    end

    it "shows 'merged' when the last PR job was closed with pr_merged" do
      job = task.jobs.create!(
        user: user, repository: repository,
        kind: "cron", scheduled_task: task, issue_number: nil, pr_number: 42
      )
      job.close_with_reason!("pr_merged")
      output = described_class.new(scheduled_task: task, fired_at: fired_at).to_s
      expect(output).to include("Last PR: #42 (merged)")
    end

    it "shows 'closed' when the last PR job was closed with pr_closed" do
      job = task.jobs.create!(
        user: user, repository: repository,
        kind: "cron", scheduled_task: task, issue_number: nil, pr_number: 17
      )
      job.close_with_reason!("pr_closed")
      output = described_class.new(scheduled_task: task, fired_at: fired_at).to_s
      expect(output).to include("Last PR: #17 (closed)")
    end

    it "picks the newest PR job when multiple exist" do
      task.jobs.create!(
        user: user, repository: repository,
        kind: "cron", scheduled_task: task, issue_number: nil, pr_number: 10
      ).tap { |j| j.close_with_reason!("pr_merged") }
      task.jobs.create!(
        user: user, repository: repository,
        kind: "cron", scheduled_task: task, issue_number: nil, pr_number: 20
      )
      output = described_class.new(scheduled_task: task, fired_at: fired_at).to_s
      expect(output).to include("Last PR: #20 (open)")
      expect(output).not_to include("#10")
    end
  end

  describe "{{last_pr_number}} template variable" do
    it "renders 'none' when there are no PR jobs" do
      task.update!(prompt: "Last PR: {{last_pr_number}}.")
      output = described_class.new(scheduled_task: task, fired_at: fired_at).to_s
      expect(output).to include("Last PR: none.")
    end

    it "renders the PR number when a PR job exists" do
      task.jobs.create!(
        user: user, repository: repository,
        kind: "cron", scheduled_task: task, issue_number: nil, pr_number: 55
      )
      task.update!(prompt: "Last PR: {{last_pr_number}}.")
      output = described_class.new(scheduled_task: task, fired_at: fired_at).to_s
      expect(output).to include("Last PR: 55.")
    end
  end

  describe "{{last_pr_state}} template variable" do
    it "renders 'none' when there are no PR jobs" do
      task.update!(prompt: "State: {{last_pr_state}}.")
      output = described_class.new(scheduled_task: task, fired_at: fired_at).to_s
      expect(output).to include("State: none.")
    end

    it "renders 'open' for a job with no closure_reason" do
      task.jobs.create!(
        user: user, repository: repository,
        kind: "cron", scheduled_task: task, issue_number: nil, pr_number: 55
      )
      task.update!(prompt: "State: {{last_pr_state}}.")
      output = described_class.new(scheduled_task: task, fired_at: fired_at).to_s
      expect(output).to include("State: open.")
    end

    it "renders 'merged' for a pr_merged closure" do
      job = task.jobs.create!(
        user: user, repository: repository,
        kind: "cron", scheduled_task: task, issue_number: nil, pr_number: 55
      )
      job.close_with_reason!("pr_merged")
      task.update!(prompt: "State: {{last_pr_state}}.")
      output = described_class.new(scheduled_task: task, fired_at: fired_at).to_s
      expect(output).to include("State: merged.")
    end
  end
end
