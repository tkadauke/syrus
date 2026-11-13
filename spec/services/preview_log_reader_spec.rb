require "rails_helper"

RSpec.describe PreviewLogReader do
  let(:job) { Factories.job_record }

  def preview_config(log_paths:)
    PreviewCommandSource::Config.new(
      start_command_for: ->(port:) { "bin/rails server -p #{port}" },
      setup_commands: [],
      seed_command: nil,
      health_check_path: "/",
      log_paths: log_paths,
      env: {},
      unset_env: []
    )
  end

  def preview_environment(workspace_path, **attrs)
    PreviewEnvironment.create!({
      job: job,
      state: "running",
      workspace_path: workspace_path,
      expires_at: 10.minutes.from_now
    }.merge(attrs))
  end

  around do |example|
    Dir.mktmpdir("preview-log-reader") do |dir|
      @workspace_path = dir
      example.run
    end
  end

  attr_reader :workspace_path

  it "tails configured log paths and marks configured files that are missing" do
    FileUtils.mkdir_p(File.join(workspace_path, "log"))
    File.write(File.join(workspace_path, "log/development.log"), "line 1\nline 2\nline 3\n")
    source = instance_double(
      PreviewCommandSource,
      resolve: preview_config(log_paths: [ "log/development.log", "log/missing.log" ])
    )
    allow(PreviewCommandSource).to receive(:new).with(workspace_path).and_return(source)

    logs = described_class.call(preview_environment(workspace_path), lines: 2)

    expect(logs.map(&:path)).to eq([ "log/development.log", "log/missing.log" ])
    expect(logs.first.content).to eq("line 2\nline 3")
    expect(logs.first.missing).to be(false)
    expect(logs.second.content).to eq("")
    expect(logs.second.missing).to be(true)
  end

  it "falls back to default Rails and Vite log paths when no preview config supplies logs" do
    FileUtils.mkdir_p(File.join(workspace_path, "log"))
    File.write(File.join(workspace_path, "log/vite.log"), "vite ready\n")
    source = instance_double(PreviewCommandSource, resolve: preview_config(log_paths: []))
    allow(PreviewCommandSource).to receive(:new).with(workspace_path).and_return(source)

    logs = described_class.call(preview_environment(workspace_path))

    expect(logs.map(&:path)).to eq([ "log/development.log", "log/vite.log" ])
    expect(logs.first).to have_attributes(content: "", missing: true)
    expect(logs.second).to have_attributes(content: "vite ready", missing: false)
  end

  it "ignores configured log paths that escape the preview workspace" do
    FileUtils.mkdir_p(File.join(workspace_path, "log"))
    File.write(File.join(workspace_path, "log/safe.log"), "inside\n")
    outside_path = File.join(Dir.tmpdir, "preview-log-reader-outside.log")
    File.write(outside_path, "outside\n")
    source = instance_double(
      PreviewCommandSource,
      resolve: preview_config(log_paths: [ "log/safe.log", "../outside.log", outside_path ])
    )
    allow(PreviewCommandSource).to receive(:new).with(workspace_path).and_return(source)

    logs = described_class.call(preview_environment(workspace_path))

    expect(logs.map(&:path)).to eq([ "log/safe.log" ])
    expect(logs.first.content).to eq("inside")
  ensure
    FileUtils.rm_f(outside_path) if outside_path
  end

  it "ignores a configured log symlink whose target escapes the preview workspace" do
    FileUtils.mkdir_p(File.join(workspace_path, "log"))
    outside_path = File.join(Dir.tmpdir, "preview-log-reader-symlink-target.log")
    File.write(outside_path, "outside\n")
    FileUtils.ln_s(outside_path, File.join(workspace_path, "log/development.log"))
    source = instance_double(
      PreviewCommandSource,
      resolve: preview_config(log_paths: [ "log/development.log" ])
    )
    allow(PreviewCommandSource).to receive(:new).with(workspace_path).and_return(source)

    expect(described_class.call(preview_environment(workspace_path))).to eq([])
  ensure
    FileUtils.rm_f(outside_path) if outside_path
  end

  it "clamps requested line counts to at least one line" do
    FileUtils.mkdir_p(File.join(workspace_path, "log"))
    File.write(File.join(workspace_path, "log/development.log"), "first\nlast\n")
    source = instance_double(
      PreviewCommandSource,
      resolve: preview_config(log_paths: [ "log/development.log" ])
    )
    allow(PreviewCommandSource).to receive(:new).with(workspace_path).and_return(source)

    logs = described_class.call(preview_environment(workspace_path), lines: 0)

    expect(logs.first.content).to eq("last")
  end

  it "returns only bytes appended after an offset and preserves line boundaries" do
    path = File.join(workspace_path, "log/development.log")
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, "first\n")
    source = instance_double(PreviewCommandSource, resolve: preview_config(log_paths: [ "log/development.log" ]))
    allow(PreviewCommandSource).to receive(:new).with(workspace_path).and_return(source)
    env = preview_environment(workspace_path)

    first = described_class.call(env).first
    File.open(path, "ab") { |file| file.write("second\n") }
    second = described_class.call(env, offsets: { first.path => first.offset }).first

    expect(second).to have_attributes(content: "\nsecond", offset: File.size(path), missing: false)
  end

  it "does not invent a newline when appended bytes continue the current line" do
    path = File.join(workspace_path, "log/development.log")
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, "first")
    source = instance_double(PreviewCommandSource, resolve: preview_config(log_paths: [ "log/development.log" ]))
    allow(PreviewCommandSource).to receive(:new).with(workspace_path).and_return(source)
    env = preview_environment(workspace_path)

    first = described_class.call(env).first
    File.open(path, "ab") { |file| file.write(" continued") }
    second = described_class.call(env, offsets: { first.path => first.offset }).first

    expect(second.content).to eq(" continued")
  end

  it "returns an empty chunk when the offset is at the end of the file" do
    path = File.join(workspace_path, "log/development.log")
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, "complete\n")
    source = instance_double(PreviewCommandSource, resolve: preview_config(log_paths: [ "log/development.log" ]))
    allow(PreviewCommandSource).to receive(:new).with(workspace_path).and_return(source)

    log = described_class.call(preview_environment(workspace_path), offsets: { "log/development.log" => File.size(path) }).first

    expect(log).to have_attributes(content: "", offset: File.size(path), missing: false)
  end

  it "restarts from the tail when the file was truncated past the offset" do
    path = File.join(workspace_path, "log/development.log")
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, "replacement\n")
    source = instance_double(PreviewCommandSource, resolve: preview_config(log_paths: [ "log/development.log" ]))
    allow(PreviewCommandSource).to receive(:new).with(workspace_path).and_return(source)

    log = described_class.call(preview_environment(workspace_path), offsets: { "log/development.log" => 1_000 }).first

    expect(log).to have_attributes(content: "replacement", offset: File.size(path), missing: false)
  end

  it "returns a missing log when a cursor names a file that does not exist" do
    path = File.join(workspace_path, "log/development.log")
    FileUtils.mkdir_p(File.dirname(path))
    source = instance_double(PreviewCommandSource, resolve: preview_config(log_paths: [ "log/development.log" ]))
    allow(PreviewCommandSource).to receive(:new).with(workspace_path).and_return(source)

    log = described_class.call(preview_environment(workspace_path), offsets: { "log/development.log" => 1 }).first

    expect(log).to have_attributes(content: "", offset: 0, missing: true)
  end

  it "restarts from the tail when truncation races the incremental read" do
    path = File.join(workspace_path, "log/development.log")
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, "replacement\n")
    source = instance_double(PreviewCommandSource, resolve: preview_config(log_paths: [ "log/development.log" ]))
    allow(PreviewCommandSource).to receive(:new).with(workspace_path).and_return(source)
    allow(File).to receive(:binread).and_call_original
    allow(File).to receive(:binread).with(path, anything, anything).and_raise(ArgumentError, "negative length")

    log = described_class.call(preview_environment(workspace_path), offsets: { "log/development.log" => 1 }).first

    expect(log).to have_attributes(content: "replacement", offset: File.size(path), missing: false)
  end

  it "returns no logs when the preview workspace no longer exists" do
    missing_workspace = File.join(workspace_path, "missing")
    env = preview_environment(missing_workspace)

    expect(described_class.call(env)).to eq([])
  end
end
