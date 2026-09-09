# frozen_string_literal: true

require "open3"
require "spec_helper"

RSpec.describe "bin/simulator", :ci_only do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "bin/simulator") }

  def run_simulator(*args)
    env = {
      "COVERAGE" => "false",
      "RAILS_ENV" => "test"
    }
    Open3.capture3(env, script, *args, chdir: root)
  end

  it "runs one named scenario" do
    stdout, stderr, status = run_simulator("spec/fixtures/work_engine_simulations/single_initial_success.yml")

    expect(status).to be_success, stderr
    expect(stdout).to include("single initial success: success")
    expect(stdout).to include("work-engine simulations passed (1 scenarios)")
  end

  it "runs the default scenario directory in series" do
    stdout, stderr, status = run_simulator

    expect(status).to be_success, stderr
    expect(stdout).to include("work-engine simulations passed")
    expect(stdout).to include("workspace missing diagnostic: stuck")
    expect(stdout).to include("(expected stuck)")
  end

  it "returns usage errors for extra arguments" do
    stdout, stderr, status = run_simulator("one.yml", "two.yml")

    expect(status.exitstatus).to eq(2)
    expect(stdout).to be_empty
    expect(stderr).to include("usage: bin/simulator")
  end
end
