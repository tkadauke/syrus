require "rails_helper"

RSpec.describe Workflows::Skill do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) do
    Job.create!(
      user: user,
      repository: repository,
      kind: "direct",
      issue_number: nil,
      issue_title: "Skill: investigate",
      skill_name: "investigate",
      skill_args: { "question" => "What does the widget do?" }
    )
  end

  describe ".trigger_kind" do
    it "is skill" do
      expect(described_class.trigger_kind).to eq("skill")
    end
  end

  describe "chain" do
    it "is prepare → run_skill → retry_until(run_skill → graders) → summarize → pr_open" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(
        %w[prepare run_skill grader_fanout grader_collect summarize pr_open]
      )
      expect(workflow.chain_template).to include(
        "type" => "retry_until",
        "max_iterations" => AppSetting.grade_max_iterations,
        "repair" => %w[run_skill],
        "check" => %w[grader_fanout grader_collect],
        "repair_first" => true
      )
    end

    it "skips prepare when the job has skip_prepare set" do
      job.update!(skip_prepare: true)
      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(
        %w[run_skill grader_fanout grader_collect summarize pr_open]
      )
    end

    it "seeds skill_name/skill_args onto the workflow's artifacts" do
      workflow = described_class.instantiate(job: job, artifacts: job.skill_workflow_artifacts)

      expect(workflow.artifact("skill_name")).to eq("investigate")
      expect(workflow.artifact("skill_args")).to eq({ "question" => "What does the widget do?" })
    end
  end

  describe "no-diff closure" do
    it "closes the Job with closure_reason=no_changes instead of :failed when run_skill produces no diff, without ever reaching the grader loop" do
      job.update!(state: "running")
      workflow = described_class.instantiate(job: job)
      run_skill_step = workflow.steps.find_by!(kind: "run_skill")
      run = Run.create!(job: job, step: run_skill_step, trigger_kind: "skill", state: "failed")
      run.create_run_diagnostic!(error_class: "Steps::Base::NoChangesProduced", error_message: "agent produced no changes")

      expect { StepDispatcher.fail_from(run_skill_step) }
        .to change { job.reload.state }.from("running").to("closed")

      expect(job.reload.closure_reason).to eq("no_changes")
      expect(workflow.reload).to be_failed

      grader_fanout_step = workflow.steps.find_by!(kind: "grader_fanout")
      expect(grader_fanout_step.runs).to be_empty
      expect(grader_fanout_step.reload.state).to eq("queued")
    end
  end

  describe "grader retry loop" do
    it "retries run_skill (not just the graders) when graders fail, up to the configured iteration bound, then falls through to failure" do
      AppSetting.current.update!(grade_max_iterations: 2)
      workflow = described_class.instantiate(job: job)

      first_run_skill = workflow.steps.find_by!(kind: "run_skill", iteration: 1)
      grader_fanout_1 = workflow.steps.find_by!(kind: "grader_fanout", iteration: 1)
      grader_collect_1 = workflow.steps.find_by!(kind: "grader_collect", iteration: 1)

      expect(first_run_skill).to be_present
      expect(grader_fanout_1).to be_present

      expect { StepDispatcher.fail_from(grader_collect_1) }
        .to change { workflow.steps.where(kind: "run_skill").count }.from(1).to(2)

      second_run_skill = workflow.steps.find_by!(kind: "run_skill", iteration: 2)
      grader_fanout_2 = workflow.steps.find_by!(kind: "grader_fanout", iteration: 2)
      grader_collect_2 = workflow.steps.find_by!(kind: "grader_collect", iteration: 2)
      expect(grader_collect_1.reload.next_step).to eq(second_run_skill)
      expect(second_run_skill.next_step).to eq(grader_fanout_2)

      expect(workflow.reload).not_to be_failed

      # Second (and final, per grade_max_iterations: 2) iteration also fails
      # its graders — the loop is exhausted, so the workflow hard-fails
      # instead of materializing a third run_skill iteration.
      expect { StepDispatcher.fail_from(grader_collect_2) }
        .not_to change { workflow.steps.where(kind: "run_skill").count }

      expect(workflow.reload).to be_failed
      expect(workflow.steps.where(kind: "run_skill", iteration: 3)).to be_empty
    end
  end
end
