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

    it "lets an ask through unless enforce_ask is set" do
      asking = ->(_req, location:) { result(:ask) }

      expect(Execution::Router.new(local:, authorizer: asking).run(request)).to eq(:ran)
      expect { Execution::Router.new(local:, authorizer: asking, enforce_ask: true).run(request) }
        .to raise_error(Execution::Router::NotAuthorized)
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

    it "logs, but does not block, a request that would ask" do
      logger = instance_double(Logger)
      expect(logger).to receive(:info).with(/would ask.*"executable":"sudo"/)
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
