require "rails_helper"

RSpec.describe Permissions::ExecutionActions do
  let(:role) { AgentRole::WORKFLOW_IMPLEMENT }

  def authorize(subject, rules: [], ceiling: Permissions::ExecutionCeiling.default)
    Permissions::ExecutionAuthorization.authorize(subject:, role:, rules:, ceiling:)
  end

  def host(command, network: "agent", env: {})
    request = Execution::Request.new(**Execution::Request.members.index_with { nil }, command:, network:, env:)
    described_class.subject_for_request(request, location: :host)
  end

  it "uses distinct, valid operations for host, container, and provider-native effects" do
    operations = described_class::LOCATIONS.map { |l| described_class.descriptor_for(l).operation }
    expect(operations.uniq.size).to eq(3)
    expect(described_class.descriptor_for(:host).classify(command: [ "ls" ])).to include(confidence: :certain)
  end

  it "classifies credentials, privilege changes, destructive work, and pushes from the command" do
    effects = ->(cmd) { described_class.classify(:container, command: cmd, network: "agent")[:effects] }

    expect(effects.call(%w[ls])).to eq(%i[isolated_execution network_read])
    expect(effects.call([ "sudo rm -rf /tmp/x" ])).to include(:privilege_change, :destructive)
    expect(effects.call([ "cat ~/.ssh/id_rsa" ])).to include(:credential_use)
    expect(effects.call([ "git push origin main" ])).to include(:external_write)
    expect(described_class.classify(:container, command: %w[ls], env_keys: %w[GITHUB_TOKEN])[:effects]).to include(:credential_use)
  end

  it "treats the loopback-only grader profile as no network use by itself" do
    expect(described_class.classify(:container, command: %w[ls], network: "grader")[:effects]).to eq(%i[isolated_execution])
  end

  it "redacts the command to an executable and digest and never carries environment values" do
    redacted = described_class.descriptor_for(:host).redact(command: [ "curl", "-H", "Authorization: x" ], env_keys: %w[A])

    expect(redacted).not_to have_key("command")
    expect(redacted).to include("executable" => "curl")
    expect(redacted["command_sha256"]).to match(/\A\h{64}\z/)
    expect(redacted.to_s).not_to include("Authorization")
  end

  it "allows plain confined work but asks for sensitive effects granted only by default" do
    expect(authorize(host(%w[ls], network: "grader"))).to be_allowed
    result = authorize(host([ "cat ~/.aws/credentials" ]))
    expect(result).to be_ask
  end

  it "allows routine open-network workflow commands without a lease" do
    expect(authorize(host([ "bundle", "install" ]))).to be_allowed
    expect(authorize(host([ "git", "fetch", "origin" ]))).to be_allowed
  end

  it "audits an execution decision with its owner and invocation identity" do
    owner = Factories.user
    subject = host(%w[ls], network: "grader")
    allow(OperationalLogging).to receive(:ingest)

    Permissions::ExecutionAuthorization.authorize(
      subject:, owner:, role:, context: { job_id: 42 }
    )

    expect(OperationalLogging).to have_received(:ingest).with(hash_including(
      source: Permissions::DecisionAudit::LOG_SOURCE,
      context: hash_including(
        actor_type: "User", actor_id: owner.id, user_id: owner.id,
        role:, job_id: 42, invocation_fingerprint: kind_of(String)
      )
    ))
  end

  it "lets an explicit deny rule win" do
    subject = host(%w[ls])
    descriptor = described_class.descriptor_for(:host)
    rule = instance_double(Permissions::PolicyRule, layer: :role, policy: :deny, id: 1, specificity: [ 0 ], delegable: false,
      match_status: :match)
    allow(rule).to receive(:match_status).and_return(:match)
    expect(authorize(subject, rules: [ rule ])).to be_denied
    expect(descriptor.operation).to eq(described_class.operation_for(:host))
  end

  describe "ceilings" do
    it "deny egress the opt-in network profile ceiling forbids even when policy would allow" do
      ceiling = Permissions::ExecutionCeiling.default.with(Permissions::ExecutionCeiling::NetworkProfile.new)
      result = authorize(host([ "curl https://example.com" ], network: "grader"), ceiling:)

      expect(result).to be_denied
      expect(result.ceilings.map(&:reason)).to eq([ :network_profile_forbids_egress ])
    end

    it "do not deny grader commands by default, since the profile enforces egress itself" do
      expect(authorize(host([ "curl http://localhost:3000" ], network: "grader"))).not_to be_denied
    end

    it "take the strictest provider limit across several effects" do
      limits = Permissions::ExecutionCeiling::ProviderLimits.new(privilege_change: :ask, destructive: :deny)
      native = described_class.subject_for_provider_action(provider: "claude", tool: "Bash", command: [ "sudo rm -rf /x" ])

      expect(authorize(native, ceiling: Permissions::ExecutionCeiling.new([ limits ]))).to be_denied
    end

    it "deny host execution under a fail-closed workload policy" do
      request = Execution::Request.new(**Execution::Request.members.index_with { nil }, command: %w[ls], network: "agent", env: {},
        workload_policy: instance_double(Execution::ChatWorkloadPolicy, fail_closed?: true))
      subject = described_class.subject_for_request(request, location: :host)

      expect(authorize(subject)).to be_denied
    end

    it "apply provider limits to provider-native actions only and never raise a decision" do
      limits = Permissions::ExecutionCeiling::ProviderLimits.new(privilege_change: :deny)
      ceiling = Permissions::ExecutionCeiling.default.with(limits)
      native = described_class.subject_for_provider_action(provider: "claude", tool: "Bash", command: [ "sudo ls" ])

      expect(authorize(native, ceiling:)).to be_denied
      expect(authorize(host([ "sudo ls" ]), ceiling:)).to be_ask
      expect(ceiling.apply(:deny, effects: %i[privilege_change], subject: native).first).to eq(:deny)
    end
  end

  describe "Execution::Router" do
    let(:request) do
      Execution::Request.new(**Execution::Request.members.index_with { nil }, command: %w[true], network: "agent", env: {},
        mounts: ProcessRunner::Mounts.new(workdir: Dir.pwd, read_write: [ Dir.pwd ]), timeout: 5)
    end
    let(:local) { Execution::Local.new.tap { |l| allow(l).to receive(:run).and_return(:ran) } }

    def result(policy)
      Permissions::ExecutionAuthorization::Result.new(decision: nil, policy:, ceilings: [],
        subject: Permissions::ExecutionActions.subject_for_request(request))
    end

    it "gates by default and still runs ordinary requests" do
      expect(Execution::Router.new(local:).send(:authorizer)).to be_a(Permissions::ExecutionGate)
      expect(Execution::Router.new(local:).run(request)).to eq(:ran)
    end

    it "does not run a denied request and tells the authorizer where it would run" do
      seen = nil
      router = Execution::Router.new(local:, authorizer: ->(_req, location:) { seen = location; result(:deny) })

      expect(local).not_to receive(:run)
      expect { router.run(request) }.to raise_error(Execution::Router::NotAuthorized)
      expect(seen).to eq(:host)
    end

    it "fails closed on ask because raw processes have no resumable approval boundary" do
      asking = ->(_req, location:) { result(:ask) }

      expect(local).not_to receive(:run)
      expect { Execution::Router.new(local:, authorizer: asking).run(request) }
        .to raise_error(Execution::Router::NotAuthorized, /execution ask/)
    end
  end

  describe Permissions::ExecutionGate do
    let(:request) do
      Execution::Request.new(**Execution::Request.members.index_with { nil }, command: %w[ls], network: "agent", env: {},
        workload_policy: instance_double(Execution::ChatWorkloadPolicy, fail_closed?: true))
    end

    it "denies a host start under a fail-closed workload and allows a container start" do
      gate = described_class.new

      expect(gate.call(request, location: :host)).to be_denied
      expect(gate.call(request, location: :container)).to be_allowed
    end

    it "records the redacted reason for an ask that the router will block" do
      logger = instance_double(Logger)
      expect(logger).to receive(:info).with(/requires approval.*"executable":"sudo"/)
      plain = request.with(command: [ "sudo", "ls" ], workload_policy: nil)

      expect(described_class.new(logger:).call(plain, location: :container)).to be_ask
    end

    it "does not treat injected token environment variables as credential use" do
      plain = request.with(env: { "GITHUB_TOKEN" => "x" }, workload_policy: nil)

      expect(described_class.new.call(plain, location: :container)).to be_allowed
    end
  end

  it "is not an MCP tool set, so it overlaps no registered tool operation" do
    tool_operations = McpToolRegistry.entries.map { |entry| entry.descriptor.operation }
    mine = described_class::LOCATIONS.map { |l| described_class.operation_for(l) }

    expect(tool_operations & mine).to be_empty
  end
end

RSpec.describe "persisted execution deny rules" do
  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user, mode: "coding") }
  let(:gate) { Permissions::ExecutionGate.new }

  def request(**attrs)
    Execution::Request.new(**Execution::Request.members.index_with { nil }, command: %w[ls], network: "agent", env: {}, **attrs)
  end

  def deny(selector_type, id: nil)
    Permissions::Management.new(user).deny!(
      { "capability" => Permissions::ExecutionActions::CAPABILITY, "operation" => Permissions::ExecutionActions.operation_for(:host),
        "role" => "any", "subject_selector_type" => selector_type, "subject_selector_id" => id }.compact,
      actor: user
    )
  end

  def allow_execution(job, selector_type, id: nil, duration: "job", command: [ "sudo", "ls" ], role: AgentRole::WORKFLOW_IMPLEMENT)
    Permissions::Management.new(user).lease!(
      { "capability" => Permissions::ExecutionActions::CAPABILITY, "operation" => Permissions::ExecutionActions.operation_for(:host),
        "role" => role, "subject_selector_type" => selector_type, "subject_selector_id" => id,
        "duration" => duration, "job_id" => (job.id if duration == "job"),
        "arguments" => { "location" => "host", "command" => command, "network" => "agent",
          "env_keys" => [], "writable_paths" => [], "provider" => "", "tool" => "" } }.compact,
      actor: user
    )
  end

  it "lists the execution operations in the permission catalog so rules can be created" do
    expect(Permissions::Catalog.find!(capability: Permissions::ExecutionActions::CAPABILITY, operation: Permissions::ExecutionActions.operation_for(:host)))
      .to have_attributes(operation: Permissions::ExecutionActions.operation_for(:host))
  end

  it "stops a coding-chat process and leaves an unrelated process running" do
    deny("coding_chat")

    expect(gate.call(request(chat_session:), location: :host)).to be_denied
    expect(gate.call(request(chat_session:), location: :container)).to be_allowed
  end

  it "stops a workflow process by role and leaves other roles running" do
    deny("workflow_role", id: AgentRole::WORKFLOW_IMPLEMENT)

    expect(gate.call(request(agent: AgentRole::WORKFLOW_IMPLEMENT, job: Job.new(user: user)), location: :host)).to be_denied
    expect(gate.call(request(agent: AgentRole::WORKFLOW_REBASE_CONFLICT, job: Job.new(user: user)), location: :host)).to be_allowed
  end

  it "does not start the backend when a persisted rule denies the request" do
    deny("coding_chat")
    local = Execution::Local.new
    expect(local).not_to receive(:run)
    req = request(chat_session:, mounts: ProcessRunner::Mounts.new(workdir: Dir.pwd, read_write: [ Dir.pwd ]), timeout: 5)

    expect { Execution::Router.new(local:).run(req) }.to raise_error(Execution::Router::NotAuthorized)
  end

  it "does not start a sensitive process when durable authority is absent" do
    local = Execution::Local.new
    expect(local).not_to receive(:run)
    req = request(
      command: [ "sudo", "ls" ], job: Job.new(user: user), agent: AgentRole::WORKFLOW_IMPLEMENT,
      mounts: ProcessRunner::Mounts.new(workdir: Dir.pwd, read_write: [ Dir.pwd ]), timeout: 5
    )

    expect { Execution::Router.new(local:).run(req) }
      .to raise_error(Execution::Router::NotAuthorized, /execution ask/)
  end

  it "starts a sensitive workflow process covered by durable Job-owner authority" do
    job = Factories.job_record(user: user)
    lease = allow_execution(job, "workflow_role", id: AgentRole::WORKFLOW_IMPLEMENT)
    local = Execution::Local.new.tap { |backend| allow(backend).to receive(:run).and_return(:ran) }
    req = request(
      command: [ "sudo", "ls" ], job:, agent: AgentRole::WORKFLOW_IMPLEMENT,
      mounts: ProcessRunner::Mounts.new(workdir: Dir.pwd, read_write: [ Dir.pwd ]), timeout: 5
    )

    expect(Execution::Router.new(local:).run(req)).to eq(:ran)
    expect(lease.effects).to include("operator_host_access", "network_read", "privilege_change")
  end

  it "does not consume invocation authority when a ceiling blocks execution" do
    job = Factories.job_record(user: user)
    lease = allow_execution(job, "workflow_role", id: AgentRole::WORKFLOW_IMPLEMENT, duration: "invocation")
    workload_policy = instance_double(Execution::ChatWorkloadPolicy, fail_closed?: true)
    req = request(command: [ "sudo", "ls" ], job:, agent: AgentRole::WORKFLOW_IMPLEMENT, workload_policy:)

    result = Permissions::ExecutionGate.new.call(req, location: :host)

    expect(result).to be_denied
    expect(lease.reload.used_count).to eq(0)
  end

  it "releases invocation authority when the backend fails before spawning" do
    job = Factories.job_record(user: user)
    lease = allow_execution(job, "workflow_role", id: AgentRole::WORKFLOW_IMPLEMENT, duration: "invocation")
    req = request(
      command: [ "sudo", "ls" ], job:, agent: AgentRole::WORKFLOW_IMPLEMENT,
      mounts: ProcessRunner::Mounts.new(workdir: Dir.pwd, read_write: [ Dir.pwd ]), timeout: 5
    )
    local = Execution::Local.new
    allow(local).to receive(:run).and_raise(Errno::ENOENT)

    expect { Execution::Router.new(local:).run(req) }.to raise_error(Errno::ENOENT)
    expect(lease.reload.used_count).to eq(0)
  end

  it "commits invocation authority when the backend reports a spawned process" do
    job = Factories.job_record(user: user)
    lease = allow_execution(job, "workflow_role", id: AgentRole::WORKFLOW_IMPLEMENT, duration: "invocation")
    callback = instance_double(Proc)
    req = request(
      command: [ "sudo", "ls" ], job:, agent: AgentRole::WORKFLOW_IMPLEMENT, on_spawned_process: callback,
      mounts: ProcessRunner::Mounts.new(workdir: Dir.pwd, read_write: [ Dir.pwd ]), timeout: 5
    )
    local = Execution::Local.new
    allow(callback).to receive(:call).with(:process)
    allow(local).to receive(:run) do |authorized_request|
      authorized_request.on_spawned_process.call(:process)
      raise Errno::EIO
    end

    expect { Execution::Router.new(local:).run(req) }.to raise_error(Errno::EIO)
    expect(lease.reload.used_count).to eq(1)
    expect(callback).to have_received(:call).with(:process)
  end

  it "does not refund invocation authority when local execution raises after spawning" do
    job = Factories.job_record(user: user)
    command = [ RbConfig.ruby, "-e", "exit 0" ]
    lease = allow_execution(job, "workflow_role", id: AgentRole::WORKFLOW_MANUAL, duration: "invocation", command:, role: AgentRole::WORKFLOW_MANUAL)
    runner = ProcessRunner.new(
      env: {}, command:, mounts: ProcessRunner.mounts(Dir.pwd), network: "agent", timeout: 5,
      kind: "agent", job:,
      on_spawned_process: ->(_process) { raise Errno::EIO }
    )

    expect { runner.run }.to raise_error(Errno::EIO)
    expect(lease.reload.used_count).to eq(1)
  end
end
