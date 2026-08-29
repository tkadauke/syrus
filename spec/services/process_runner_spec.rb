require "rails_helper"
require "rbconfig"
require "tmpdir"

RSpec.describe ProcessRunner, :ci_only do
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

  it "calls back when a spawned process row is registered" do
    spawned_processes = []

    result = described_class.new(
      env: {},
      command: [ ruby, "-e", "exit 0" ],
      chdir: @dir,
      timeout: 5,
      kind: "agent",
      on_spawned_process: ->(process) { spawned_processes << process }
    ).run

    expect(result).to be_success
    expect(spawned_processes.size).to eq(1)
    expect(spawned_processes.first).to have_attributes(kind: "agent", workdir: @dir)
    expect(spawned_processes.first.finished_at).to be_nil
    expect(spawned_processes.first.reload).to be_finished
    expect(spawned_processes.first.resource_attribution).to include("method" => "linux_proc_process_group")
  end

  it "attributes the spawned process row to a chat session when given one" do
    chat_session = ChatSession.create!(user: Factories.user)

    result = described_class.new(
      env: {},
      command: [ ruby, "-e", "exit 0" ],
      chdir: @dir,
      timeout: 5,
      kind: "chat_prepare",
      chat_session: chat_session
    ).run

    expect(result).to be_success
    spawned_process = SpawnedProcess.order(:id).last
    expect(spawned_process.chat_session).to eq(chat_session)
  end

  it "keeps command span attribution distinct from spawned process attribution" do
    job = Factories.job_record
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
    step = Step.create!(workflow: workflow, kind: "grader", position: 0, state: "running")
    run = Run.create!(
      job: job,
      step: step,
      trigger_kind: "initial",
      agent_provider: "claude",
      state: "running",
      started_at: Time.current
    )
    span = nil

    result = described_class.new(
      env: {},
      command: [ ruby, "-e", "exit 0" ],
      chdir: @dir,
      timeout: 5,
      kind: "grader",
      run: run,
      workflow: workflow,
      on_spawned_process: ->(process) do
        span = CommandSpan.create!(
          job: job,
          workflow: workflow,
          step: step,
          run: run,
          spawned_process: process,
          sequence: 1,
          name: "rspec",
          command_excerpt: "bin/rspec",
          hostname: process.hostname,
          started_at: Time.current
        )
      end
    ).run

    process = SpawnedProcess.find(result.spawned_process_id)
    expect(process.resource_attribution).to include("method" => "linux_proc_process_group")
    expect(span.reload.resource_attribution).to include(
      "method" => "spawned_process_owned",
      "sample_count" => 0,
      "unavailable_reason" => "process-group resource attribution is owned by the spawned process"
    )
  end

  it "heartbeats a run while a silent spawned process is still alive" do
    job = Factories.job_record
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
    step = Step.create!(workflow: workflow, kind: "prepare", position: 0, state: "running")
    run = Run.create!(
      job: job,
      step: step,
      trigger_kind: "initial",
      agent_provider: "claude",
      state: "running",
      started_at: Time.current
    )

    result = described_class.new(
      env: {},
      command: [ ruby, "-e", "sleep 0.2" ],
      chdir: @dir,
      timeout: 5,
      kind: "prepare",
      run: run,
      workflow: workflow
    ).run

    expect(result).to be_success
    expect(run.reload.last_heartbeat_at).to be_within(2.seconds).of(Time.current)
    expect(SpawnedProcess.find(result.spawned_process_id).last_chunk_at).to be_present
  end

  it "uses the shared run heartbeat throttle for process heartbeats" do
    job = Factories.job_record
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
    step = Step.create!(workflow: workflow, kind: "prepare", position: 0, state: "running")
    run = Run.create!(
      job: job,
      step: step,
      trigger_kind: "initial",
      agent_provider: "claude",
      state: "running",
      started_at: Time.zone.parse("2026-08-20T11:59:00Z"),
      last_heartbeat_at: nil
    )
    runner = described_class.new(env: {}, command: [ ruby, "-e", "exit 0" ], chdir: @dir, timeout: 5, run: run)

    runner.send(:heartbeat_run!, Time.zone.parse("2026-08-20T12:00:00Z"))
    runner.send(:heartbeat_run!, Time.zone.parse("2026-08-20T12:00:05Z"))

    expect(run.reload.last_heartbeat_at).to eq(Time.zone.parse("2026-08-20T12:00:00Z"))
  end

  it "updates run heartbeats even when spawned process heartbeats are throttled" do
    job = Factories.job_record
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running")
    step = Step.create!(workflow: workflow, kind: "prepare", position: 0, state: "running")
    run = Run.create!(
      job: job,
      step: step,
      trigger_kind: "initial",
      agent_provider: "claude",
      state: "running",
      started_at: Time.zone.parse("2026-08-20T11:59:00Z"),
      last_heartbeat_at: Time.zone.parse("2026-08-20T11:59:00Z")
    )
    process = SpawnedProcess.create!(
      kind: "agent",
      command: "agent",
      hostname: "worker-a",
      started_at: 2.minutes.ago,
      last_chunk_at: 5.seconds.ago
    )
    # Compare against the persisted value (not the pre-save in-memory Time)
    # so this assertion isn't sensitive to sub-microsecond float rounding
    # across the DB round-trip -- only whether heartbeat! left it untouched.
    process_last_chunk_at = process.reload.last_chunk_at
    runner = described_class.new(env: {}, command: [ ruby, "-e", "exit 0" ], chdir: @dir, timeout: 5, run: run)
    runner.instance_variable_set(:@spawned_process, process)

    runner.send(:heartbeat!)

    expect(run.reload.last_heartbeat_at).to be_within(2.seconds).of(Time.current)
    expect(process.reload.last_chunk_at).to be_within(0.001.seconds).of(process_last_chunk_at)
  end

  it "throttles spawned process resource attribution writes between liveness heartbeats" do
    process = SpawnedProcess.create!(
      kind: "agent",
      command: "agent",
      hostname: "worker-a",
      started_at: 2.minutes.ago,
      last_chunk_at: 1.minute.ago,
      resource_attribution: { "method" => "initial" }
    )
    sampler = double("sampler", sample!: nil, payload: { "method" => "sampled" })
    runner = described_class.new(env: {}, command: [ ruby, "-e", "exit 0" ], chdir: @dir, timeout: 5)
    runner.instance_variable_set(:@spawned_process, process)
    runner.instance_variable_set(:@resource_sampler, sampler)
    runner.instance_variable_set(:@last_resource_attribution_persisted_at, Time.current)

    runner.send(:heartbeat!)

    expect(sampler).not_to have_received(:sample!)
    expect(process.reload.last_chunk_at).to be_within(2.seconds).of(Time.current)
    expect(process.resource_attribution).to eq("method" => "initial")
  end

  it "refreshes spawned process resource attribution once the throttle window elapses" do
    process = SpawnedProcess.create!(
      kind: "agent",
      command: "agent",
      hostname: "worker-a",
      started_at: 2.minutes.ago,
      last_chunk_at: 1.minute.ago,
      resource_attribution: { "method" => "initial" }
    )
    sampler = double("sampler", sample!: nil, payload: { "method" => "sampled" })
    runner = described_class.new(env: {}, command: [ ruby, "-e", "exit 0" ], chdir: @dir, timeout: 5)
    runner.instance_variable_set(:@spawned_process, process)
    runner.instance_variable_set(:@resource_sampler, sampler)
    runner.instance_variable_set(
      :@last_resource_attribution_persisted_at,
      (ProcessRunner::RESOURCE_ATTRIBUTION_UPDATE_INTERVAL_SECONDS + 1).seconds.ago
    )

    runner.send(:heartbeat!)

    expect(sampler).to have_received(:sample!)
    expect(process.reload.resource_attribution).to eq("method" => "sampled")
  end

  it "reconciles a stopped chat turn when the process exits before output" do
    user = Factories.user(claude_oauth_token: "oat-test")
    chat = ChatSession.create!(user: user, workspace_path: @dir, stop_requested_at: Time.current)
    chat.messages.create!(role: "user", content: { "text" => "Stop before output" })

    result = described_class.new(
      env: {},
      command: [ ruby, "-e", "exit 0" ],
      chdir: @dir,
      timeout: 5,
      kind: "agent"
    ).run

    expect(result).to be_success
    expect(chat.reload.stop_requested_at).to be_nil
    expect(chat).not_to be_turn_in_flight
    expect(chat.messages.order(:created_at).pluck(:role, :content)).to include(
      [ "system", { "text" => "Cancelled by operator." } ]
    )
  end

  it "records truncated command strings without splitting UTF-8 characters" do
    prefix = [ ruby, "-e", "exit 0", "" ].join(" ")
    filler = "a" * (4095 - prefix.bytesize)

    result = described_class.new(
      env: {},
      command: [ ruby, "-e", "exit 0", "#{filler}€tail" ],
      chdir: @dir,
      timeout: 5,
      kind: "agent"
    ).run

    process = SpawnedProcess.order(:id).last
    expect(result).to be_success
    expect(process.command.bytesize).to be <= 4096
    expect(process.command).to be_valid_encoding
  end

  it "redacts GitHub credentials before storing spawned process commands" do
    result = described_class.new(
      env: {},
      command: [ ruby, "-e", "exit 0" ],
      chdir: @dir,
      timeout: 5,
      kind: "git",
      display_command: "git clone https://x-access-token:ghp_storesecret@github.com/acme/widgets.git"
    ).run

    process = SpawnedProcess.find(result.spawned_process_id)
    expect(process.command).to eq("git clone https://x-access-token:[REDACTED]@github.com/acme/widgets.git")
    expect(process.command).not_to include("ghp_storesecret")
    expect(process.command).not_to include("x-access-token:ghp_")
  end

  it "kills the subprocess when silent_timeout elapses with no output" do
    # The subprocess prints once and then sleeps — past silent_timeout
    # with no further output, ProcessRunner must terminate it and
    # surface silent_timed_out so the agent caller can fail the Run
    # quickly instead of holding its SolidQueue claim open.
    result = described_class.new(
      env: {},
      command: [ ruby, "-e", "STDOUT.sync = true; puts 'starting'; sleep 10" ],
      chdir: @dir,
      timeout: 30,
      silent_timeout: 0.5,
      kill_grace_seconds: 0
    ).run

    expect(result).to be_silent_timed_out
    expect(result).not_to be_timed_out
    expect(result).not_to be_success
    expect(result.exit_status).to be_nil
    expect(result.duration_s).to be < 5
  end

  it "detects a parent that exits while a child holds the stdout pipe open" do
    # Reproduces today's edge case: the agent process exits but a
    # child it spawned inherits the stdout fd and keeps the pipe
    # alive, so the Ruby reader never sees EOF. ProcessRunner's
    # aliveness probe (`Process.kill 0, parent_pid`) detects the
    # parent's death directly and terminates the process group.
    skip "bash not available" unless system("which bash >/dev/null 2>&1")

    result = described_class.new(
      env: {},
      command: [ "bash", "-c", "sleep 10 & disown; exit 0" ],
      chdir: @dir,
      timeout: 30,
      silent_timeout: nil,
      kill_grace_seconds: 0
    ).run

    # Without the aliveness probe, the run would hang at least 10s
    # waiting for the disowned child's pipe to close. With the probe,
    # it completes in well under a second.
    expect(result).to be_success
    expect(result).not_to be_aliveness_failed
    expect(result.exit_status).to eq(0)
    expect(result.duration_s).to be < 3
  end

  it "does not kill a process that keeps producing output within silent_timeout" do
    # The subprocess prints every 100ms for 0.8 seconds, well under
    # silent_timeout once the Ruby child has booted. Keep enough
    # startup headroom for full-suite load so this spec measures
    # output cadence, not interpreter startup time.
    script = <<~RUBY
      STDOUT.sync = true
      8.times do
        puts 'tick'
        sleep 0.1
      end
    RUBY
    result = described_class.new(
      env: {},
      command: [ ruby, "-e", script ],
      chdir: @dir,
      timeout: 30,
      silent_timeout: 2
    ).run

    expect(result).to be_success
    expect(result).not_to be_silent_timed_out
  end

  it "builds forwarded env from an allowlist plus explicit extras" do
    saved = ENV.to_h
    ENV.replace("HOME" => "/tmp/home", "RAILS_MASTER_KEY" => "secret")

    env = described_class.forwarded_env(%w[HOME], extra: { "TOKEN" => "x", "EMPTY" => nil })

    expect(env).to eq("HOME" => "/tmp/home", "TOKEN" => "x")
  ensure
    ENV.replace(saved)
  end

  it "delivers stdin_data to the child" do
    lines = []
    result = described_class.new(
      env: {},
      command: [ ruby, "-e", "print STDIN.read.bytesize" ],
      chdir: @dir,
      timeout: 5,
      stdin_data: "hello stdin",
      on_output_line: ->(line) { lines << line }
    ).run

    expect(result).to be_success
    expect(lines.join).to eq("hello stdin".bytesize.to_s)
  end

  it "delivers an initial stdin byte before a slow-scheduled writer thread can run" do
    prompt = "x" * (described_class::SYNC_STDIN_BYTES + 1)
    lines = []
    original_thread_new = Thread.method(:new)

    allow(Thread).to receive(:new).and_wrap_original do |_original, *args, &block|
      if args.first == prompt.byteslice(described_class::SYNC_STDIN_BYTES..)
        original_thread_new.call(*args) do |*thread_args|
          sleep 0.3
          block.call(*thread_args)
        end
      else
        original_thread_new.call(*args, &block)
      end
    end

    script = <<~RUBY
      ready, = IO.select([ STDIN ], nil, nil, 0.1)
      unless ready
        warn "Warning: no stdin data received in 0.1s, proceeding without it."
        exit 7
      end

      print STDIN.read.bytesize
    RUBY

    result = described_class.new(
      env: {},
      command: [ ruby, "-e", script ],
      chdir: @dir,
      timeout: 5,
      stdin_data: prompt,
      on_output_line: ->(line) { lines << line }
    ).run

    expect(result).to be_success
    expect(lines.join).to eq(prompt.bytesize.to_s)
  end

  it "does not deadlock when a large stdin payload is written while the child streams output" do
    # The payload (2 MiB) far exceeds the ~64 KiB stdin pipe buffer, and the
    # child echoes every line back — so a synchronous stdin write would wedge
    # (we block writing stdin; child blocks writing stdout nobody reads yet).
    # The concurrent writer thread must prevent that.
    big = "x" * (2 * 1024 * 1024)
    script = 'n = 0; STDIN.each_line { |l| n += l.bytesize }; STDOUT.puts n'
    total_bytes = nil

    result = Timeout.timeout(20) do
      described_class.new(
        env: {},
        command: [ ruby, "-e", script ],
        chdir: @dir,
        timeout: 15,
        stdin_data: big + "\n",
        on_output_line: ->(line) { total_bytes = line.to_i }
      ).run
    end

    expect(result).to be_success
    expect(total_bytes).to eq(big.bytesize + 1)
  end

  def run_command(*command)
    described_class.new(env: {}, command: command, chdir: @dir, timeout: 5).run
  end

  def ruby
    RbConfig.ruby
  end
end
