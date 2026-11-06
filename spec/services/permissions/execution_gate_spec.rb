require "rails_helper"

RSpec.describe Permissions::ExecutionGate do
  def request(kind: "grader", run: nil, workflow: nil, job: nil, chat_session: nil, command: [ "true" ])
    Execution::Request.new(
      env: {}, command: command, chdir: Dir.pwd, mounts: ProcessRunner.mounts(Dir.pwd),
      network: "grader", resource_limits: nil, timeout: 5, stdin_data: nil,
      unsetenv_others: true, pgroup: true, stop_requested: -> { false },
      on_output_chunk: nil, on_output_line: nil,
      kill_grace_seconds: ProcessRunner::TERM_GRACE_SECONDS, silent_timeout: nil,
      activity_probe: nil, kind: kind, run: run, workflow: workflow, job: job,
      chat_session: chat_session, agent: nil, display_command: nil,
      on_spawned_process: nil, workload_policy: nil, local_runner: nil
    )
  end

  # The regression. Asset precompilation shells out to brotli through
  # ProcessRunner with no kind and no actor; the gate evaluated it anyway,
  # returned ask, and Execution::Router failed closed -- so no image could be
  # built at all.
  it "holds no opinion on an execution with neither a kind nor an actor" do
    expect(described_class.new.call(request(kind: nil))).to be_nil
    expect(described_class.new.call(request(kind: ""))).to be_nil
  end

  it "still evaluates a tracked execution with no actor" do
    expect(described_class.new.call(request(kind: "agent"))).not_to be_nil
  end

  it "still evaluates an execution that has an actor but no kind" do
    job = Factories.job

    expect(described_class.new.call(request(kind: nil, job: job))).not_to be_nil
  end

  it "still evaluates when only a workflow attributes the execution" do
    workflow = Factories.job.workflows.first

    expect(described_class.new.call(request(kind: nil, workflow: workflow))).not_to be_nil
  end

  describe "harness plumbing" do
    # The outage this closes: the harness composes its own argv, so an agent
    # policy had nothing to decide and failed closed on it. `git push` read
    # as an external write blocked branches from publishing and
    # `git checkout --detach` read as destructive blocked every distributed
    # grader -- each as a separate incident, because an allowlist of harness
    # kinds only grows one outage at a time.
    %w[git grader prepare filesystem archive runtime_probe preview].each do |kind|
      it "holds no opinion on #{kind}" do
        expect(described_class.new.call(request(kind: kind, job: Factories.job))).to be_nil
      end
    end

    it "does not gate a force push the harness composed" do
      push = [ "git", "push", "--force-with-lease", "https://x-access-token:s@github.com/o/r.git", "HEAD:b" ]

      expect(described_class.new.call(request(kind: "git", job: Factories.job, command: push))).to be_nil
    end

    it "still evaluates the process that runs the model" do
      expect(described_class.new.call(request(kind: "agent", job: Factories.job))).not_to be_nil
    end

    it "still evaluates an operator-written shell command" do
      expect(described_class.new.call(request(kind: "chat_shell_command", job: Factories.job))).not_to be_nil
    end
  end

  describe "through Execution::Router" do
    # End-to-end reproduction: this is the shape `assets:precompile` builds,
    # and it raised Execution::Router::NotAuthorized before the fix.
    it "lets build plumbing reach the backend instead of requiring approval" do
      # Asserting it gets as far as the local backend's own argument check is
      # the precise claim: authorization was passed, not merely that some
      # other error happened to be raised first.
      expect { Execution::Router.new.run(request(kind: nil)) }
        .to raise_error(Execution::Backend::InvalidRequest, /local_runner/)
    end

    # The gate skipping unattributed work must not weaken the fail-closed path
    # for work it does judge. A raw process has no exact-invocation replay
    # boundary, so anything short of an explicit allow has to stop it.
    it "still fails closed when the authorizer withholds approval" do
      subject = Struct.new(:location).new(:host)
      withheld = Struct.new(:policy, :subject) do
        def allowed? = false
      end.new("ask", subject)

      expect { Execution::Router.new(authorizer: ->(_req, location:) { withheld }).run(request(kind: "grader")) }
        .to raise_error(Execution::Router::NotAuthorized, /ask for host process/)
    end
  end
end
