require "rails_helper"
require "rbconfig"
require "tmpdir"

RSpec.describe ProcessRunner do
  around do |example|
    Dir.mktmpdir("process-runner") do |dir|
      @dir = dir
      example.run
    end
  end

  it "returns a successful result for exit 0" do
    result = run_command(ruby, "-e", "exit 0")

    expect(result).to be_success
    expect(result.exit_status).to eq(0)
    expect(result).not_to be_timed_out
  end

  it "returns a failed result for nonzero exit" do
    result = run_command(ruby, "-e", "exit 7")

    expect(result).not_to be_success
    expect(result.exit_status).to eq(7)
  end

  it "streams output to line and chunk callbacks" do
    lines = []
    chunks = +""

    result = described_class.new(
      env: {},
      command: [ ruby, "-e", "puts 'one'; print 'two'" ],
      chdir: @dir,
      timeout: 5,
      on_output_line: ->(line) { lines << line },
      on_output_chunk: ->(chunk) { chunks << chunk }
    ).run

    expect(result).to be_success
    expect(lines).to eq([ "one\n", "two" ])
    expect(chunks).to include("one\n")
    expect(chunks).to include("two")
  end

  it "times out and terminates the process group" do
    result = described_class.new(
      env: {},
      command: [ ruby, "-e", "sleep 10" ],
      chdir: @dir,
      timeout: 0.05,
      kill_grace_seconds: 0
    ).run

    expect(result).to be_timed_out
    expect(result.exit_status).to be_nil
    expect(result).not_to be_success
  end

  it "stops when the stop callback becomes true" do
    lines = []
    stop_after_first_line = false

    result = described_class.new(
      env: {},
      command: [ ruby, "-e", "STDOUT.sync = true; puts 'ready'; sleep 10" ],
      chdir: @dir,
      timeout: 5,
      kill_grace_seconds: 0,
      stop_requested: -> { stop_after_first_line },
      on_output_line: ->(line) do
        lines << line
        stop_after_first_line = true
      end
    ).run

    expect(lines.first).to eq("ready\n")
    expect(result).to be_stopped
    expect(result).not_to be_timed_out
    expect(result).not_to be_success
  end

  it "runs with only the env it is given" do
    saved = ENV.to_h
    ENV["SHOULD_NOT_LEAK"] = "secret"
    chunks = +""

    described_class.new(
      env: { "VISIBLE" => "yes", "PATH" => ENV.fetch("PATH") },
      command: [ ruby, "-e", "puts ENV.fetch('VISIBLE'); puts ENV.key?('SHOULD_NOT_LEAK')" ],
      chdir: @dir,
      timeout: 5,
      on_output_chunk: ->(chunk) { chunks << chunk }
    ).run

    expect(chunks.lines.map(&:chomp)).to eq([ "yes", "false" ])
  ensure
    ENV.replace(saved)
  end

  it "builds forwarded env from an allowlist plus explicit extras" do
    saved = ENV.to_h
    ENV.replace("HOME" => "/tmp/home", "RAILS_MASTER_KEY" => "secret")

    env = described_class.forwarded_env(%w[HOME], extra: { "TOKEN" => "x", "EMPTY" => nil })

    expect(env).to eq("HOME" => "/tmp/home", "TOKEN" => "x")
  ensure
    ENV.replace(saved)
  end

  def run_command(*command)
    described_class.new(env: {}, command: command, chdir: @dir, timeout: 5).run
  end

  def ruby
    RbConfig.ruby
  end
end
