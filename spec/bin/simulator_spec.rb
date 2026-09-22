# frozen_string_literal: true

require "open3"
require "fileutils"
require "spec_helper"

RSpec.describe "bin/simulator", :ci_only do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "bin/simulator") }

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

  it "isolates standalone invocations from the default test database" do
    default_db_paths = [
      File.join(root, "storage/test.sqlite3"),
      File.join(root, "storage/test_search.sqlite3")
    ]
    default_db_paths.each { |path| FileUtils.rm_f(path) }

    stdout, stderr, status = run_simulator("spec/fixtures/work_engine_simulations/single_initial_success.yml")

    expect(status).to be_success, stderr
    expect(stdout).to include("single initial success: success")
    expect(default_db_paths).to all(satisfy { |path| !File.exist?(path) })
  ensure
    default_db_paths&.each { |path| FileUtils.rm_f(path) }
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
