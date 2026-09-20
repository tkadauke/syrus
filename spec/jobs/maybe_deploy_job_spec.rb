require "rails_helper"

RSpec.describe MaybeDeployJob do
  include ActiveJob::TestHelper

  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }
  let(:github_client) { instance_double(GithubClient) }
  let(:sha) { "abc123def456" }

  # `.syrus.yml` is read through GitHub (App::DeployAvailability ->
  # RepoDefaultBranchSyrusYml) rather than the repository's local bare
  # clone -- see "Deploy target" in CLAUDE.md ("Web pods don't need this
  # volume"). No $SYRUS_DATA_ROOT clone is created anywhere in this spec.
  # `is_a?(GithubClient)` is stubbed true since RepoDefaultBranchSyrusYml
  # gates the fetched client on that check and an `instance_double`
  # otherwise fails it.
  def stub_syrus_yml(content)
    result = content ? { content: content, size: content.bytesize } : nil
    allow(github_client).to receive(:file_content_at)
      .with(repository.slug, SyrusYml::CONFIG_FILE, repository.default_branch)
      .and_return(result)
  end

  def configure_continuous_deploy!(min_interval_minutes: nil)
    yml = +"deploy:\n  run: bin/deploy\n  mode: continuous\n"
    yml << "  min_interval_minutes: #{min_interval_minutes}\n" if min_interval_minutes
    stub_syrus_yml(yml)
  end

  before do
    allow(StepDispatcher).to receive(:start_workflow)
    allow(GithubClient).to receive(:for).and_return(github_client)
    allow(github_client).to receive(:is_a?).with(GithubClient).and_return(true)
    allow(github_client).to receive(:branch_head_sha).and_return(sha)
  end

  it "does nothing when the repository does not exist" do
    expect { described_class.perform_now(0) }.not_to change(Job, :count)
  end

  it "does nothing for an archived repository" do
    configure_continuous_deploy!
    repository.archive!

    expect { described_class.perform_now(repository.id) }.not_to change(Job, :count)
  end

  it "does nothing when deploy is not configured" do
    stub_syrus_yml("prepare:\n  - bundle install\n")

    expect { described_class.perform_now(repository.id) }.not_to change(Job, :count)
  end

  it "does nothing when deploy.mode is manual (the default)" do
    stub_syrus_yml("deploy:\n  run: bin/deploy\n")

    expect { described_class.perform_now(repository.id) }.not_to change(Job, :count)
  end

  describe "when eligible" do
    it "creates a deploy anchor Job targeting the current default-branch HEAD" do
      configure_continuous_deploy!

      expect { described_class.perform_now(repository.id) }.to change(Job, :count).by(1)

      job = Job.last
      expect(job.kind).to eq("deploy")
      expect(job.repository).to eq(repository)
      expect(job.user).to eq(user)
      expect(job.issue_number).to be_nil
      expect(job.issue_title).to eq("deploy:#{sha}")
    end

    it "launches a Workflows::Deploy workflow pinned to the resolved sha" do
      configure_continuous_deploy!

      expect { described_class.perform_now(repository.id) }.to change(Workflow, :count).by(1)

      workflow = Workflow.last
      expect(workflow.trigger_kind).to eq("deploy")
      expect(workflow.artifact("deploy_sha")).to eq(sha)
      expect(StepDispatcher).to have_received(:start_workflow).once
    end

    it "excludes the anchor Job from the operator dashboard's user job_type filter" do
      configure_continuous_deploy!
      described_class.perform_now(repository.id)

      expect(Filters::Chips::Jobs::JobType.system_kinds).to include(Job.last.kind)
      expect(Filters::Chips::Jobs::JobType.user_kinds).not_to include(Job.last.kind)
    end

    it "does nothing when the default-branch HEAD sha cannot be resolved" do
      configure_continuous_deploy!
      allow(github_client).to receive(:branch_head_sha).and_return(nil)

      expect { described_class.perform_now(repository.id) }.not_to change(Job, :count)
    end
  end

  describe "when another deploy Workflow is already active" do
    before do
      configure_continuous_deploy!
      active_job = Job.create!(
        user: user, repository: repository, kind: "deploy",
        issue_title: "deploy:previous", issue_number: nil
      )
      Workflows::Deploy.instantiate(job: active_job, artifacts: { "deploy_sha" => "previous" }).tap do |wf|
        wf.update!(state: "running")
      end
    end

    it "is a no-op" do
      expect { described_class.perform_now(repository.id) }.not_to change(Job, :count)
    end

    it "does not reschedule itself" do
      expect { described_class.perform_now(repository.id) }
        .not_to have_enqueued_job(MaybeDeployJob)
    end
  end

  describe "min_interval_minutes throttle" do
    def create_finished_deploy_workflow!(finished_at:)
      job = Job.create!(
        user: user, repository: repository, kind: "deploy",
        issue_title: "deploy:old", issue_number: nil
      )
      workflow = Workflows::Deploy.instantiate(job: job, artifacts: { "deploy_sha" => "old" })
      workflow.update!(state: "succeeded", finished_at: finished_at)
      job.update_columns(state: "closed", finished_at: finished_at)
      workflow
    end

    it "reschedules instead of dropping the trigger when still inside the throttle window" do
      configure_continuous_deploy!(min_interval_minutes: 15)
      create_finished_deploy_workflow!(finished_at: 5.minutes.ago)
      expected_time = 10.minutes.from_now
      jobs_before = Job.count

      expect { described_class.perform_now(repository.id) }
        .to have_enqueued_job(MaybeDeployJob).with(repository.id).at(a_value_within(5.seconds).of(expected_time))

      expect(Job.count).to eq(jobs_before)
    end

    it "launches immediately once the throttle window has passed" do
      configure_continuous_deploy!(min_interval_minutes: 15)
      create_finished_deploy_workflow!(finished_at: 20.minutes.ago)

      expect { described_class.perform_now(repository.id) }.to change(Job, :count).by(1)
      expect(Job.last.kind).to eq("deploy")
    end

    it "launches immediately when no prior deploy Workflow has finished" do
      configure_continuous_deploy!(min_interval_minutes: 15)

      expect { described_class.perform_now(repository.id) }.to change(Job, :count).by(1)
    end

    it "launches immediately when min_interval_minutes is not configured" do
      configure_continuous_deploy!
      create_finished_deploy_workflow!(finished_at: 1.minute.ago)

      expect { described_class.perform_now(repository.id) }.to change(Job, :count).by(1)
    end
  end
end
