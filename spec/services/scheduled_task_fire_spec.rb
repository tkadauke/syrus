require "rails_helper"

RSpec.describe ScheduledTaskFire do
  let(:user) { Factories.user(github_token: "ghp_x") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:task) do
    ScheduledTask.create!(
      user: user, repository: repository,
      name: "Weekly tests", prompt: "Write missing tests.",
      kind: "cron", cron_expression: "0 9 * * 1", pr_pileup_policy: "skip"
    )
  end

  def make_open_pr_job(pr_number: 99)
    task.jobs.create!(
      user: user, repository: repository,
      kind: "cron", scheduled_task: task,
      issue_number: nil, pr_number: pr_number
    )
  end

  describe "#call" do
    it "spawns a cron Job with an explicit initial Run carrying the rendered prompt" do
      result = described_class.new(task).call

      expect(result).to be_fired
      expect(result.job).to be_present
      expect(result.job.kind).to eq("cron")
      expect(result.job.scheduled_task).to eq(task)
      expect(result.job.issue_number).to be_nil

      run = result.job.runs.first
      expect(run.trigger_kind).to eq("initial")
      expect(run.prompt).to include("scheduled maintenance task")
      expect(run.prompt).to include("Write missing tests")
      expect(run.workflow.work_unit).to be_present
    end

    it "stores only the operator's interpolated prompt in issue_body, not the full scaffolded render" do
      result = described_class.new(task).call

      expect(result.job.issue_body).to eq("Write missing tests.")
      expect(result.job.issue_body).not_to include("scheduled maintenance task")
      expect(result.job.issue_body).not_to include("Standing instruction context")
      expect(result.job.issue_body).not_to include("submit_summary")

      run = result.job.runs.first
      expect(run.prompt).to include("scheduled maintenance task")
      expect(run.prompt).to include("Standing instruction context")
      expect(run.prompt).to include("submit_summary")
    end

    it "keeps Depends-on text in the rendered prompt without parsing dependencies" do
      Job.create!(user: user, repository: repository, issue_number: 42)
      task.update!(prompt: "Write missing tests.\nDepends-on: #42")

      result = described_class.new(task).call

      expect(result.job.issue_body).to include("Depends-on: #42")
      expect(result.job.dependencies).to be_empty
      expect(result.job.runs.first.prompt).to include("Depends-on: #42")
    end

    it "stamps last_fired_at on the task" do
      freeze_time do
        described_class.new(task).call
        expect(task.reload.last_fired_at).to eq(Time.current)
      end
    end

    it "does not spawn a second Job in the same hourly fire window" do
      now = Time.utc(2026, 5, 4, 9, 10, 0)
      first_copy = ScheduledTask.find(task.id)
      second_copy = ScheduledTask.find(task.id)

      expect {
        described_class.new(first_copy, now: now).call
        result = described_class.new(second_copy, now: now + 20.minutes).call
        expect(result).not_to be_fired
        expect(result.reason).to eq("already_fired_window")
      }.to change { Job.count }.by(1)
    end

    it "uses the same window guard for poll and manual fires" do
      task.update!(cron_expression: "5 9 * * 1", minute_offset: 49)
      now = Time.utc(2026, 5, 4, 9, 5, 0)

      poll_result = described_class.new(task, now: now, require_due: true).call
      manual_result = described_class.new(task, now: now + 10.minutes).call

      expect(poll_result).to be_fired
      expect(manual_result).not_to be_fired
      expect(manual_result.reason).to eq("already_fired_window")
    end

    context "skip policy" do
      it "does not spawn a Job when a prior PR is still open" do
        make_open_pr_job
        expect { described_class.new(task).call }.not_to change { Job.count }
      end

      it "still stamps last_fired_at so the next due-check baselines from this tick" do
        make_open_pr_job
        freeze_time do
          described_class.new(task).call
          expect(task.reload.last_fired_at).to eq(Time.current)
        end
      end

      it "returns a skipped result with reason 'prior_pr_open'" do
        make_open_pr_job
        result = described_class.new(task).call
        expect(result).not_to be_fired
        expect(result.reason).to eq("prior_pr_open")
      end
    end

    context "pile policy" do
      it "spawns a new Job even when a prior PR is still open" do
        task.update!(pr_pileup_policy: "pile")
        make_open_pr_job
        expect { described_class.new(task).call }.to change { Job.count }.by(1)
      end
    end

    context "replace policy" do
      it "closes prior open-PR Jobs before spawning the new one" do
        task.update!(pr_pileup_policy: "replace")
        old = make_open_pr_job
        allow_any_instance_of(GithubClient).to receive(:close_pull_request).and_return(nil)

        described_class.new(task).call

        expect(old.reload.state).to eq("closed")
        expect(old.closure_reason).to eq("replaced_by_scheduled_task")
      end

      it "tolerates GitHub close errors and still spawns the new Job" do
        task.update!(pr_pileup_policy: "replace")
        make_open_pr_job
        allow_any_instance_of(GithubClient).to receive(:close_pull_request).and_raise(StandardError, "boom")

        expect { described_class.new(task).call }.to change { Job.count }.by(1)
      end
    end

    context "skill tasks" do
      # Override the outer github_token-carrying user so Skills.for resolves
      # "investigate" as a built-in without a repo-local GitHub lookup.
      let(:user) { Factories.user }
      let(:task) do
        ScheduledTask.create!(
          user: user, repository: repository,
          name: "Investigate weekly", prompt: nil,
          skill_name: "investigate", skill_args: { "question" => "What changed recently?" },
          kind: "cron", cron_expression: "0 9 * * 1", pr_pileup_policy: "skip"
        )
      end

      it "spawns a cron Job carrying skill_name/skill_args and dispatches a Workflows::Skill" do
        result = described_class.new(task).call

        expect(result).to be_fired
        job = result.job
        expect(job.kind).to eq("cron")
        expect(job.scheduled_task).to eq(task)
        expect(job.skill_name).to eq("investigate")
        expect(job.skill_args).to eq({ "question" => "What changed recently?" })

        workflow = job.workflows.last
        expect(workflow.trigger_kind).to eq("skill")
        expect(workflow.work_unit).to be_present
        expect(workflow.artifact("skill_name")).to eq("investigate")
        expect(workflow.artifact("skill_args")).to eq({ "question" => "What changed recently?" })
      end

      it "leaves the initial Run's prompt unset so Steps::RunSkill renders it on its own turn" do
        result = described_class.new(task).call

        run = result.job.runs.first
        expect(run.prompt).to be_blank
      end

      it "renders a preview issue_body via Skills::Renderer" do
        result = described_class.new(task).call

        expect(result.job.issue_body).to include("What changed recently?")
      end

      it "still honors pr_pileup_policy for skill tasks" do
        task.jobs.create!(
          user: user, repository: repository,
          kind: "cron", scheduled_task: task,
          issue_number: nil, pr_number: 99
        )

        expect { described_class.new(task).call }.not_to change { Job.count }
      end
    end

    context "one_shot tasks" do
      let(:task) do
        ScheduledTask.create!(
          user: user, repository: repository,
          name: "One-time bump", prompt: "Bump deps.",
          kind: "one_shot", fire_at: 1.minute.from_now, pr_pileup_policy: "skip"
        )
      end

      it "transitions to fired after spawning the Job" do
        described_class.new(task).call
        expect(task.reload).to be_fired
      end
    end
  end
end
