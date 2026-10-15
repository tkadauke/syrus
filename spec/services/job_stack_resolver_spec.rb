require "rails_helper"

RSpec.describe JobStackResolver, :ci_only do
  let(:job) { Factories.job }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial") }

  # Regression for the stack-child git-state-corruption false positive:
  # RebaseTarget.branch_for prefers a pinned `rebase_base_branch` Workflow
  # artifact over recomputing `open_parent_branch(job)` live. Before this
  # fix, JobStackResolver only ever populated that artifact for the fan-in
  # ("prepared_stack_base") case -- an ordinary single-parent stack
  # resolution left `resolution.artifacts` empty, so every fresh
  # WorkflowWorkspace instance within the Workflow re-resolved the parent
  # branch from the parent Job's *current* live state. If the parent closed
  # partway through the Workflow, a later Run's recomputed base_ref could
  # diverge from what the original clone actually fetched.
  describe "#resolve!" do
    it "pins the resolved single stack parent's branch onto the result artifacts" do
      prerequisite = Factories.job(repository: job.repository, issue_number: 99)
      prerequisite.update!(branch_name: "syrus/issue-99-#{prerequisite.id}", pr_number: 99)
      prerequisite.runs.create!(trigger_kind: "initial", agent_provider: prerequisite.agent_provider, head_sha: "c" * 40)
      JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual")

      result = described_class.new(job, workflow: workflow).resolve!

      expect(result).to be_ready
      expect(result.parent).to eq(prerequisite)
      expect(result.artifacts).to eq(RebaseTarget::BASE_BRANCH_ARTIFACT => prerequisite.branch_name)
    end

    it "pins the branch even when the Job already points at that parent (no-op update path)" do
      prerequisite = Factories.job(repository: job.repository, issue_number: 99)
      prerequisite.update!(branch_name: "syrus/issue-99-#{prerequisite.id}", pr_number: 99)
      prerequisite.runs.create!(trigger_kind: "initial", agent_provider: prerequisite.agent_provider, head_sha: "c" * 40)
      JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual")
      job.update!(parent_job: prerequisite)

      result = described_class.new(job, workflow: workflow).resolve!

      expect(result.artifacts).to eq(RebaseTarget::BASE_BRANCH_ARTIFACT => prerequisite.branch_name)
    end

    it "does not pin anything when the Job has no stackable parent (falls back to the default branch)" do
      result = described_class.new(job, workflow: workflow).resolve!

      expect(result).to be_ready
      expect(result.parent).to be_nil
      expect(result.artifacts).to eq({})
    end

    it "includes deployment-stage gate details in dependency blocker payloads" do
      staging = SyrusYml::DeploymentStage.new(name: "staging", label: "On Staging", tag: "staging", tag_pattern: nil)
      production = SyrusYml::DeploymentStage.new(name: "production", label: "Production", tag: "production", tag_pattern: nil)
      allow(RepoDeploymentStagesReader).to receive(:for_repository).and_return(
        RepoDeploymentStagesReader::Result.new(stages: [ staging, production ], source: ".syrus.yml", note: nil)
      )
      prerequisite = Factories.job_record(repository: job.repository, state: "closed", landed_sha: "abc123")
      prerequisite.deployment_stage_statuses.create!(stage_name: "staging", reached_at: Time.zone.parse("2026-07-30T12:00:00Z"))
      JobDependency.create!(
        job: job,
        depends_on_job: prerequisite,
        source: "manual",
        satisfaction_mode: "deployment_stage",
        required_deployment_stage_name: "production"
      )

      result = described_class.new(job, workflow: workflow).resolve!
      dependency = result.blocker.fetch("dependencies").first

      expect(result).not_to be_ready
      expect(dependency).to include(
        "satisfaction_mode" => "deployment_stage",
        "required_deployment_stage_name" => "production",
        "latest_deployment_stage" => include(name: "staging", label: "On Staging")
      )
    end

    it "reuses a previously prepared fan-in base when dependency heads have not changed" do
      epic = Factories.epic(user: job.user, repository: job.repository, state: "in_progress")
      job.update!(epic: epic)
      dep_a = approved_dependency(epic, 1574, "syrus/issue-1574", "a" * 40)
      dep_b = approved_dependency(epic, 1575, "syrus/issue-1575", "b" * 40)
      [ dep_a, dep_b ].each { |dependency| Factories.legacy_job_dependency(job: job, depends_on_job: dependency) }
      dependencies = [
        { "job_id" => dep_a.id, "branch_name" => dep_a.branch_name, "head_sha" => dep_a.head_sha },
        { "job_id" => dep_b.id, "branch_name" => dep_b.branch_name, "head_sha" => dep_b.head_sha }
      ]
      build = JobStackPreparedBaseBuilder::Result.new(
        true,
        "prepared",
        "syrus/prepared-base-#{job.id}-#{workflow.id}",
        "d" * 40,
        dependencies,
        "prepared fan-in execution base"
      )
      builder = instance_double(JobStackPreparedBaseBuilder)

      expect(builder).to receive(:call).once.with(contain_exactly(dep_a, dep_b)).and_return(build)

      first = described_class.new(job, workflow: workflow, prepared_base_builder: builder).resolve!
      workflow.update!(artifacts: workflow.artifacts.to_h.merge(first.artifacts))
      second = described_class.new(job.reload, workflow: workflow.reload, prepared_base_builder: builder).resolve!

      expect(first).to be_ready
      expect(second).to be_ready
      expect(second.artifacts).to eq(first.artifacts)
    end

    it "rebuilds a prepared fan-in base when a dependency head has changed" do
      epic = Factories.epic(user: job.user, repository: job.repository, state: "in_progress")
      job.update!(epic: epic)
      dep_a = approved_dependency(epic, 1574, "syrus/issue-1574", "a" * 40)
      dep_b = approved_dependency(epic, 1575, "syrus/issue-1575", "b" * 40)
      [ dep_a, dep_b ].each { |dependency| Factories.legacy_job_dependency(job: job, depends_on_job: dependency) }
      workflow.update!(
        artifacts: {
          "prepared_stack_base" => {
            "succeeded" => true,
            "reason" => "prepared",
            "branch_name" => "syrus/prepared-base-#{job.id}-#{workflow.id}",
            "head_sha" => "d" * 40,
            "dependencies" => [
              { "job_id" => dep_a.id, "branch_name" => dep_a.branch_name, "head_sha" => "0" * 40 },
              { "job_id" => dep_b.id, "branch_name" => dep_b.branch_name, "head_sha" => dep_b.head_sha }
            ]
          }
        }
      )
      build = JobStackPreparedBaseBuilder::Result.new(
        true,
        "prepared",
        "syrus/prepared-base-#{job.id}-#{workflow.id}",
        "e" * 40,
        [
          { "job_id" => dep_a.id, "branch_name" => dep_a.branch_name, "head_sha" => dep_a.head_sha },
          { "job_id" => dep_b.id, "branch_name" => dep_b.branch_name, "head_sha" => dep_b.head_sha }
        ],
        "prepared fan-in execution base"
      )
      builder = instance_double(JobStackPreparedBaseBuilder)

      expect(builder).to receive(:call).once.with(contain_exactly(dep_a, dep_b)).and_return(build)

      result = described_class.new(job, workflow: workflow, prepared_base_builder: builder).resolve!

      expect(result).to be_ready
      expect(result.artifacts.fetch("prepared_stack_base")).to include("head_sha" => "e" * 40)
    end
  end

  def approved_dependency(epic, issue_number, branch_name, head_sha)
    dependency = Factories.job_record(
      user: job.user,
      repository: job.repository,
      epic: epic,
      state: "approved",
      issue_number: issue_number,
      branch_name: branch_name,
      pr_number: issue_number
    )
    dependency.runs.create!(trigger_kind: "initial", state: "succeeded", head_sha: head_sha)
    dependency
  end
end
