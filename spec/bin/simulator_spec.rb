# frozen_string_literal: true

require "open3"
require "fileutils"
require "spec_helper"

RSpec.describe "bin/simulator", :ci_only do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "bin/simulator") }

  # Existence plus inode, so a file that was deleted and recreated is caught
  # even when the replacement happens to be the same size. Deliberately not
  # mtime or size: the rspec process running this example holds the same
  # database open and legitimately writes to it.
  def database_identity(path)
    return :absent unless File.exist?(path)

    File.stat(path).ino
  end

  def run_simulator(*args, env: {})
    # Clear TEST_ENV_NUMBER unless an example sets one: under parallel_rspec
    # it holds this worker's number, and the simulator would then run
    # against the worker's own test<N>.sqlite3 instead of its stable
    # "_simulator" database.
    env = {
      "COVERAGE" => "false",
      "RAILS_ENV" => "test",
      "TEST_ENV_NUMBER" => nil
    }.merge(env)
    Open3.capture3(env, script, *args, chdir: root)
  end

  it "runs one named scenario" do
    stdout, stderr, status = run_simulator("spec/fixtures/work_engine_simulations/single_initial_success.yml")

    expect(status).to be_success, stderr
    expect(stdout).to include("single initial success: success")
    expect(stdout).to include("work-engine simulations passed (1 scenarios)")
  end

  # Each scenario runs inside a wrapper transaction that is rolled back at the
  # end. While that wrapper was joinable, it swallowed every inner commit: a
  # `save` joined the wrapper instead of opening its own transaction, so
  # `after_commit` callbacks were deferred to an outer commit that never came.
  # The simulator was therefore blind to the entire commit-callback layer --
  # Step#advance_next_step!, Run#propagate_succeeded_run!,
  # Workflow#schedule_auto_retry!, Job#start_dependent_jobs_after_implementation
  # -- and the per-tick "wake every job" pass silently stood in for all of it.
  #
  # This scenario's dependent Job starts only from that callback chain, so it
  # gets stuck if the wrapper is ever made joinable again.
  it "runs after_commit callbacks inside a scenario" do
    stdout, stderr, status = run_simulator("spec/fixtures/work_engine_simulations/job_dependency_success.yml")

    expect(status).to be_success, stderr
    expect(stdout).to include("job dependency success: success")
  end

  # This used to delete storage/test.sqlite3 and storage/test_search.sqlite3
  # before and after the run, to prove the simulator did not create them. But
  # that is the database the rspec process running this very example is
  # connected to. SQLite keeps an unlinked file usable through the open
  # handle, so the examples already in flight kept passing while any process
  # that opened a *new* connection -- a spawned sidecar, an Evals::CLI run --
  # got a freshly created empty file and failed with "no such table: users".
  #
  # Only the serial `ci_only` pass was affected, because the parallel workers
  # use storage/test<N>.sqlite3 and this example is tagged ci_only. The result
  # was thousands of failures attributed to whatever change was under test,
  # which reported main as broken and made the main-branch repair Job
  # unfixable: its own grader hit the same wipe.
  #
  # The property worth asserting is that a standalone invocation does not
  # touch the default database, which identity checks establish without
  # destroying anything.
  it "isolates standalone invocations from the default test database" do
    default_db_paths = [
      File.join(root, "storage/test.sqlite3"),
      File.join(root, "storage/test_search.sqlite3")
    ]
    before = default_db_paths.to_h { |path| [ path, database_identity(path) ] }

    stdout, stderr, status = run_simulator("spec/fixtures/work_engine_simulations/single_initial_success.yml")

    expect(status).to be_success, stderr
    expect(stdout).to include("single initial success: success")

    after = default_db_paths.to_h { |path| [ path, database_identity(path) ] }
    expect(after).to eq(before),
      "bin/simulator must not create, delete or replace the default test database"
  end

  it "prepares the test database when invoked from a fresh checkout" do
    suffix = "_simulator_fresh_#{Process.pid}"
    db_paths = [
      File.join(root, "storage/test#{suffix}.sqlite3"),
      File.join(root, "storage/test_search#{suffix}.sqlite3")
    ]
    db_paths.each { |path| FileUtils.rm_f(path) }

    stdout, stderr, status = run_simulator(
      "spec/fixtures/work_engine_simulations/parallel_grader_worker_loss_retries.yml",
      env: { "TEST_ENV_NUMBER" => suffix }
    )

    expect(status).to be_success, stderr
    expect(stdout).to include("parallel grader worker loss retries: success")
    expect(stdout).to include("work-engine simulations passed (1 scenarios)")
  ensure
    db_paths&.each { |path| FileUtils.rm_f(path) }
  end

  it "reuses the stable-suffix database across invocations instead of rebuilding it from scratch" do
    db_path = File.join(root, "storage/test_simulator.sqlite3")
    search_db_path = File.join(root, "storage/test_search_simulator.sqlite3")
    stale_paths = [ db_path, search_db_path ].flat_map { |path| [ path, "#{path}-shm", "#{path}-wal" ] }
    stale_paths.each { |path| FileUtils.rm_f(path) }

    first_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stdout1, stderr1, status1 = run_simulator("spec/fixtures/work_engine_simulations/single_initial_success.yml")
    first_duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - first_started_at

    expect(status1).to be_success, stderr1
    expect(stdout1).to include("single initial success: success")
    expect(File.exist?(db_path)).to be(true)

    second_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    stdout2, stderr2, status2 = run_simulator("spec/fixtures/work_engine_simulations/single_initial_success.yml")
    second_duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - second_started_at

    expect(status2).to be_success, stderr2
    expect(stdout2).to include("single initial success: success")
    # The first invocation pays the full cost of loading db/schema.rb's 150+
    # tables into a fresh file; a second invocation against the same
    # (persisted) database should only need a fast schema-checksum check.
    # A regression that goes back to a fresh random database per run would
    # make the two invocations take roughly the same time.
    expect(second_duration).to be < first_duration
  ensure
    stale_paths&.each { |path| FileUtils.rm_f(path) }
  end

  it "runs the default scenario directory in series" do
    stdout, stderr, status = run_simulator

    expect(status).to be_success, stderr
    expect(stdout).to include("work-engine simulations passed")
    expect(stdout).to include("workspace missing diagnostic: stuck")
    expect(stdout).to include("(expected stuck)")
  end

  it "resolves symbolic alternate providers with no agent-provider plugins manually enabled" do
    stdout, stderr, status = run_simulator("spec/fixtures/work_engine_simulations/provider_switch_relaunches_blocked_work.yml")

    expect(status).to be_success, stderr
    expect(stdout).to include("provider switch relaunches blocked work: success")
    expect(stdout).to include("work-engine simulations passed (1 scenarios)")
  end

  it "returns usage errors for extra arguments" do
    stdout, stderr, status = run_simulator("one.yml", "two.yml")

    expect(status.exitstatus).to eq(2)
    expect(stdout).to be_empty
    expect(stderr).to include("usage: bin/simulator")
  end
end
