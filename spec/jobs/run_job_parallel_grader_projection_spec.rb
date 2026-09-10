require "rails_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "shellwords"

RSpec.describe "RunJob distributed legacy grader projections", :ci_only do
  self.use_transactional_tests = false

  include ActiveJob::TestHelper

  let(:bare_remote_dir) { Pathname.new(Dir.mktmpdir("syrus-parallel-grader-bare")) }
  let(:data_root) { Dir.mktmpdir("syrus-parallel-grader-data") }
  let(:timing_log_path) { File.join(data_root, "grader-timing.log") }
  let(:user) { Factories.user(name: "Ada Lovelace", github_token: "ghp_test_token") }
  let(:repository) do
    Factories.repository(
      user: user,
      owner: "acme",
      name: "parallel-graders",
      default_branch: "main",
      distributed_workflow_dag_enabled: true
    )
  end

  around do |example|
    previous_data_root = ENV["SYRUS_DATA_ROOT"]
    ENV["SYRUS_DATA_ROOT"] = data_root
    clear_persisted_records!
    clear_enqueued_jobs
    example.run
  ensure
    clear_enqueued_jobs
    clear_persisted_records!
    ENV["SYRUS_DATA_ROOT"] = previous_data_root
    FileUtils.rm_rf(bare_remote_dir)
    FileUtils.rm_rf(data_root)
    ActiveRecord::Base.connection_handler.clear_all_connections!
  end

  before do
    seed_remote_with_parallel_graders
    Feature.find_or_create_by!(slug: "distributed_workflow_dag") do |feature|
      feature.category = "Operations"
      feature.name = "Distributed workflow DAG"
    end.update!(enabled: true)
    AppSetting.current.update!(workflow_step_worker_slot_admission_enabled: true)
    allow_any_instance_of(Repository).to receive(:remote_url).and_return("file://#{bare_remote_dir}")
    allow_any_instance_of(Repository).to receive(:authenticated_push_url).and_return("file://#{bare_remote_dir}")
    allow(GithubAuthenticatedGit).to receive(:run) { |**_, &block| block.call("file://#{bare_remote_dir}") }
    allow(SyrusVersion).to receive(:hostname) { Thread.current[:syrus_test_worker_hostname] || "worker-main" }
    allow(WorkerStorageIdentity).to receive(:queue_key) { Thread.current[:syrus_test_worker_storage_key] || "storage-main" }
    allow(InstanceVersion).to receive(:worker_queue_live?).and_return(true)
  end

  it "runs materialized legacy grader projections with overlapping wall-clock windows across simulated workers" do
    job = Factories.job_record(user: user, repository: repository, issue_number: 42, state: "running", branch_name: "syrus/direct-parallel")
    workflow = Workflow.create!(job: job, user: user, trigger_kind: "initial", agent_provider: job.agent_provider, state: "running")
    collect = Step.create!(workflow: workflow, kind: "grader_collect", position: 1, iteration: 1)
    fanout = Step.create!(
      workflow: workflow,
      kind: "grader_fanout",
      position: 0,
      iteration: 1,
      next_step_id: collect.id,
      placement_policy: Step::PlacementPolicy::CONTROL_PLANE
    )
    fanout_run = fanout.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)

    allow_any_instance_of(RunJob).to receive(:next_inline_run).and_return(nil)
    RunJob.perform_now(fanout_run.id)

    grader_steps = workflow.reload.steps.where(kind: "grader").order(:position).to_a
    expect(grader_steps.map { |step| step.details.fetch("name") }).to eq(%w[alpha beta])
    expect(grader_steps.map(&:next_step_id)).to eq([ collect.id, collect.id ])
    expect(collect.reload.depends_on_step_ids).to eq(grader_steps.map(&:id))

    perform_grader_runs_concurrently!(grader_steps.map { |step| step.runs.sole })

    collect_run = collect.reload.runs.sole
    RunJob.perform_now(collect_run.id) if collect_run.queued?

    expect(grader_steps.map { |step| step.reload.state }).to eq(%w[succeeded succeeded])
    expect(collect.reload).to be_succeeded
    expect(workflow.reload).to be_succeeded
    expect(GraderConclusion.where(workflow: workflow).where.not(grader_name: GraderConclusion::AGGREGATE_NAME).pluck(:grader_name, :status)).to contain_exactly(
      [ "alpha", "passed" ],
      [ "beta", "passed" ]
    )
    expect(GraderConclusion.aggregate.where(workflow: workflow).sole.status).to eq("passed")
    expect(overlapping_timing_windows?).to be(true)
    expect(workflow.artifact("grader_loops").first).to include(
      "grader_count" => 2,
      "failed_required_count" => 0
    )
    expect(workflow.artifact("grader_loops").first.fetch("wall_clock_s")).to be > 0
    expect(workflow.artifact("grader_loops").first.fetch("summed_duration_s")).to be > 0
    expect(WorkflowStepWorkerSlot.where(workflow: workflow).pluck(:worker_storage_key)).to include("storage-alpha", "storage-beta")
  end

  private

  def perform_grader_runs_concurrently!(runs)
    errors = Queue.new
    threads = runs.map do |run|
      name = run.step.details.fetch("name")
      Thread.new do
        Thread.current[:syrus_test_worker_storage_key] = "storage-#{name}"
        Thread.current[:syrus_test_worker_hostname] = "worker-#{name}"
        ActiveRecord::Base.connection_pool.with_connection do
          RunJob.perform_now(run.id)
        rescue StandardError => e
          errors << e
        end
      ensure
        Thread.current[:syrus_test_worker_storage_key] = nil
        Thread.current[:syrus_test_worker_hostname] = nil
      end
    end
    threads.each(&:join)
    raise errors.pop unless errors.empty?
  end

  def overlapping_timing_windows?
    windows = File.readlines(timing_log_path, chomp: true).each_with_object({}) do |line, memo|
      name, event, timestamp = line.split(/\s+/, 3)
      memo[name] ||= {}
      memo[name][event] = timestamp.to_f
    end
    alpha = windows.fetch("alpha")
    beta = windows.fetch("beta")

    alpha.fetch("start") < beta.fetch("finish") && beta.fetch("start") < alpha.fetch("finish")
  end

  def seed_remote_with_parallel_graders
    Dir.mktmpdir("syrus-parallel-grader-seed") do |seed|
      sh("git init -q -b main #{seed}")
      File.write(File.join(seed, "README.md"), "parallel graders\n")
      File.write(File.join(seed, ".syrus.yml"), <<~YAML)
        prepare: []
        grade:
          - name: alpha
            run: #{grader_command("alpha").to_json}
          - name: beta
            run: #{grader_command("beta").to_json}
      YAML
      sh("git -C #{seed} add README.md .syrus.yml")
      sh("git -C #{seed} commit -q -m 'seed parallel graders'")
      FileUtils.mkdir_p(bare_remote_dir.dirname)
      sh("git clone -q --bare #{seed} #{bare_remote_dir}")
    end
  end

  def grader_command(name)
    <<~RUBY.squish
      ruby -e 'path, name = ARGV;
      File.open(path, "a") { |file| file.puts "\#{name} start \#{Time.now.to_f}" };
      sleep 0.75;
      File.open(path, "a") { |file| file.puts "\#{name} finish \#{Time.now.to_f}" };
      puts "\#{name} passed"' #{Shellwords.escape(timing_log_path)} #{Shellwords.escape(name)}
    RUBY
  end

  def clear_persisted_records!
    User.destroy_all
    Feature.where(slug: "distributed_workflow_dag").delete_all
    AppSetting.delete_all
  end

  def sh(command)
    out, err, status = Open3.capture3(
      {
        "GIT_AUTHOR_NAME" => "Seed",
        "GIT_AUTHOR_EMAIL" => "seed@example.com",
        "GIT_COMMITTER_NAME" => "Seed",
        "GIT_COMMITTER_EMAIL" => "seed@example.com"
      },
      command
    )
    raise "command failed: #{command}\n#{out}\n#{err}" unless status.success?

    out
  end
end
