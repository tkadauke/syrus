require "rails_helper"

RSpec.describe RepositoryExecutionProbeRunner do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }
  let(:probe) { RepositoryExecutionProbe.create!(repository:, requested_by: user, result: {}) }
  let(:runner) { described_class.new(probe, git: instance_double(GitRunner)) }

  before do
    allow(runner).to receive(:clone!) do
      FileUtils.mkdir_p(runner.send(:path))
      File.write(runner.send(:path).join(".syrus.yml"), "prepare:\n  - missing-setup\ngrade:\n  - name: specs\n    run: bin/specs\n")
    end
    allow(runner).to receive(:git_output).with("rev-parse", "HEAD").and_return("abc123\n")
  end

  it "records a required command startup failure and always removes the checkout" do
    allow(runner).to receive(:run_command) do |command, **options|
      entry = { "kind" => options[:kind], "command" => command, "required" => options[:required], "success" => false, "exit_status" => 127, "could_not_start" => true }
      runner.instance_variable_get(:@commands) << entry
      entry
    end

    runner.call

    expect(probe.reload).to be_blocked
    expect(probe).to be_implementation_blocking
    expect(probe.result).to include("cleanup" => "completed", "summary" => a_string_matching(/first implementation run is blocked/))
    expect(runner.send(:path)).not_to exist
  end

  it "records a successful bounded grader probe" do
    allow(runner).to receive(:run_command) do |command, **options|
      entry = { "kind" => options[:kind], "command" => command, "required" => options[:required], "success" => true, "exit_status" => 0, "duration_s" => 0.1 }
      runner.instance_variable_get(:@commands) << entry
      entry
    end

    runner.call

    expect(probe.reload).to be_succeeded
    expect(probe.result.fetch("commands").map { |entry| entry["command"] }).to eq([ "missing-setup", "bin/specs" ])
    expect(probe.result["cleanup"]).to eq("completed")
  end
end
