require "rails_helper"

RSpec.describe CredentialStore::PermissionProvider do
  it "classifies read-only diagnostics separately while offering exact durable SSH authority" do
    descriptor = described_class.capability_descriptor("ssh.execute/risky@v1")

    read = Permissions::InvocationClassifier.call(
      descriptor:, arguments: { command: "uname -a" }
    )
    risky = Permissions::InvocationClassifier.call(
      descriptor:, arguments: { command: "sudo systemctl restart app" }
    )

    expect(read).to have_attributes(
      operation: "ssh.execute/read@v1", risk: :high, fallback?: false
    )
    expect(risky).to have_attributes(
      operation: "ssh.execute/risky@v1", risk: :critical, fallback?: false
    )
    expect(descriptor).to have_attributes(
      maximum_autonomy: :permanent, authority_durations: %i[invocation chat_session permanent]
    )
    expect(descriptor.effects).to include(:credential_use, :external_write, :operational)
    expect(descriptor.defaults.values.uniq).to eq([ :ask ])
  end

  it "issues and consumes exact invocation authority for a classified read-only command" do
    owner = Factories.user
    read_descriptor = described_class.capability_descriptor("ssh.execute/read@v1")
    advertised_descriptor = described_class.capability_descriptor("ssh.execute/risky@v1")
    role = AgentRole::CHAT_PLANNER
    context = { subject_selector_type: "interactive_chat" }
    resource_scope = {
      credential: "production", host: "api.example.com", user: "deploy", port: 22
    }
    arguments = resource_scope.merge(command: "uname -a")

    lease = Permissions::AuthorityGrant.issue!(
      duration: :invocation, descriptor: read_descriptor, owner:, actor: owner,
      subject_selector_type: "interactive_chat", role:, resource_scope:, context:, arguments:
    )
    result = Permissions::LeaseAuthorizer.call(
      descriptor: advertised_descriptor, owner:, role:, resource_scope:, context:, arguments:
    )

    expect(result).to be_authorized
    expect(result.lease).to eq(lease)
    expect(lease.reload.used_count).to eq(1)
  end

  it "scopes authority to a prefix of credential, host, user and port" do
    schema = described_class.permission_resource_scopes.fetch(:ssh_destination)
    context = {}
    destination = schema.normalize(
      { credential: "production", host: "API.EXAMPLE.COM", user: "deploy", port: "2222" }, context:
    )

    expect(destination).to have_attributes(status: :ok)
    expect(destination.value).to eq(
      "credential" => "production", "host" => "api.example.com", "user" => "deploy", "port" => 2222
    )
    expect(schema.normalize({ credential: "production", host: "api.example.com", user: "deploy", port: "invalid" }, context:))
      .to have_attributes(status: :invalid, errors: include("port must be between 1 and 65535"))
  end

  # The scope a broad rule carries. An absent field has to stay absent, or the
  # rule normalizes to blanks that compare disjoint from every destination --
  # and because a failed comparison is decisive, that denies the operation
  # outright instead of asking.
  it "keeps an unset field out of the normalized scope so a broad rule stays representable" do
    schema = described_class.permission_resource_scopes.fetch(:ssh_destination)
    context = {}

    expect(schema.normalize({}, context:)).to have_attributes(status: :ok, value: {})
    expect(schema.normalize({ credential: "production" }, context:))
      .to have_attributes(status: :ok, value: { "credential" => "production" })
    expect(schema.normalize({ credential: "production", host: "API.EXAMPLE.COM" }, context:))
      .to have_attributes(status: :ok, value: { "credential" => "production", "host" => "api.example.com" })
  end

  # A gap is the case that must still fail closed: `scope_path` compacts, so a
  # host without its credential would be compared against an unrelated prefix.
  it "fails closed on a scope that skips a level of the hierarchy" do
    schema = described_class.permission_resource_scopes.fetch(:ssh_destination)
    context = {}

    expect(schema.normalize({ host: "api.example.com" }, context:))
      .to have_attributes(status: :invalid, errors: include("host requires credential"))
    expect(schema.normalize({ credential: "production", user: "deploy" }, context:))
      .to have_attributes(status: :invalid, errors: include("user requires host"))
    expect(schema.normalize({ credential: "production", host: "api.example.com", port: 2222 }, context:))
      .to have_attributes(status: :invalid, errors: include("port requires user"))
  end

  it "labels every stopping point an operator can be shown" do
    schema = described_class.permission_resource_scopes.fetch(:ssh_destination)
    context = {}
    labels = lambda do |scope|
      result = schema.label(scope, context:)
      expect(result).to have_attributes(status: :ok)
      result.value
    end

    expect(labels.call({})).to eq("Any SSH destination")
    expect(labels.call({ credential: "production" })).to eq("Any SSH destination via credential production")
    expect(labels.call({ credential: "production", host: "api.example.com" })).to eq("SSH api.example.com (any user)")
    expect(labels.call({ credential: "production", host: "api.example.com", user: "deploy" }))
      .to eq("SSH deploy@api.example.com")
    expect(labels.call({ credential: "production", host: "api.example.com", user: "deploy", port: 2222 }))
      .to eq("SSH deploy@api.example.com:2222")
  end

  # The defect this guards: an `allow` rule written for any destination could
  # never match a real one, and a failed scope comparison is decisive, so the
  # evaluator answered `deny` -- never reaching the capability's `ask` default
  # and never producing an approval card for the operator.
  it "authorizes a concrete destination from a rule scoped to any destination" do
    descriptor = described_class.capability_descriptor("ssh.execute/read@v1")
    arguments = { credential: 4, host: "api.example.com", user: "deploy", command: "ls -lh /config" }
    context = { subject_selector_type: "interactive_chat", role: AgentRole::CHAT_PLANNER }

    decision = Permissions::PolicyEvaluator.new(
      descriptor:, role: AgentRole::CHAT_PLANNER,
      resource_scope: descriptor.resource_scope_for(arguments), arguments:, context:,
      rules: [ Permissions::PolicyRule.new(
        id: "1", layer: "agent", policy: "allow", source: "permission_profile:full_access@v1",
        capability: "ssh.execute@v1", operation: "ssh.execute/read@v1", resource_scope: {},
        constraints: {}, selectors: { subject_selector_type: "interactive_chat" },
        delegable: true, rationale: "spec"
      ) ]
    ).call

    expect(decision.policy).to eq(:allow)
  end

  it "authorizes any host reachable with a credential the rule names, and nothing beyond it" do
    descriptor = described_class.capability_descriptor("ssh.execute/read@v1")
    context = { subject_selector_type: "interactive_chat", role: AgentRole::CHAT_PLANNER }
    rule = Permissions::PolicyRule.new(
      id: "1", layer: "agent", policy: "allow", source: "spec",
      capability: "ssh.execute@v1", operation: "ssh.execute/read@v1",
      resource_scope: { "credential" => 4 }, constraints: {},
      selectors: { subject_selector_type: "interactive_chat" }, delegable: true, rationale: "spec"
    )
    policy_for = lambda do |arguments|
      Permissions::PolicyEvaluator.new(
        descriptor:, role: AgentRole::CHAT_PLANNER,
        resource_scope: descriptor.resource_scope_for(arguments), arguments:, context:, rules: [ rule ]
      ).call.policy
    end

    expect(policy_for.call(credential: 4, host: "api.example.com", user: "deploy", command: "ls")).to eq(:allow)
    expect(policy_for.call(credential: 4, host: "other.example.com", user: "root", command: "ls")).to eq(:allow)
    # A different credential is outside the rule, so the capability's own
    # default for this role decides -- which is to ask, not to deny.
    expect(policy_for.call(credential: 7, host: "api.example.com", user: "deploy", command: "ls")).to eq(:ask)
  end

  # The operator-facing half of the same defect. The Permissions Hub builds
  # each surface's column by probing the descriptor with an empty resource
  # scope, so while `{}` failed to normalize, SSH rendered as `deny` on every
  # chat surface no matter which rules existed -- telling an operator their
  # grant had not taken effect, and that the thing to change was a policy that
  # was already set.
  it "reports the capability's own role default to the operator rather than a fail-closed deny" do
    owner = Factories.user
    management = Permissions::Management.new(owner)

    %w[ssh.execute/read@v1 ssh.execute/risky@v1].each do |operation|
      descriptor = described_class.capability_descriptor(operation)
      state = management.matrix_state(
        descriptor:, role: AgentRole::CHAT_PLANNER, subject_selector_type: "interactive_chat", active_rules: []
      )
      expect(state).to eq("ask"), "expected #{operation} to render as ask, got #{state}"
    end
  end

  it "does not disclose credentials that are absent or invisible to the invocation context" do
    schema = described_class.permission_resource_scopes.fetch(:ssh_destination)
    mcp_context = instance_double(McpToolContext)
    allow(CredentialStore::Broker).to receive(:resolve_credential!)
      .with(context: mcp_context, credential_ref: "hidden")
      .and_raise(CredentialStore::Broker::NotFound, "credential not found")

    expect(schema.lookup("hidden", context: { mcp_context: })).to have_attributes(status: :not_found)
  end

  it "fingerprints the command and authorization bypass flags without retaining command text" do
    descriptor = described_class.capability_descriptor("ssh.execute/risky@v1")
    arguments = {
      credential: "production", host: "api.example.com", user: "deploy",
      command: "cat /etc/os-release", allow_risky_command: false
    }
    normalized = descriptor.normalize_fingerprint(arguments)
    changed_command = Permissions::InvocationFingerprint.call(
      descriptor:, arguments: arguments.merge(command: "uname -a")
    )
    changed_destination = Permissions::InvocationFingerprint.call(
      descriptor:, arguments: arguments.merge(host: "other.example.com")
    )

    expect(normalized).not_to include("command")
    expect(normalized.fetch("command_sha256")).to eq(Digest::SHA256.hexdigest("cat /etc/os-release"))
    expect(descriptor.redact(arguments)).to include(
      "credential_name" => "production", "command" => "cat /etc/os-release"
    )
    expect(Permissions::InvocationFingerprint.call(descriptor:, arguments:)).not_to eq(changed_command)
    expect(Permissions::InvocationFingerprint.call(descriptor:, arguments:)).not_to eq(changed_destination)
  end

  it "redacts common SSH command secrets and fails closed without a reviewable command" do
    descriptor = described_class.capability_descriptor("ssh.execute/risky@v1")
    base = { credential: "production", host: "api.example.com", user: "deploy" }

    password = descriptor.redact(base.merge(command: "curl --password=hunter2 https://api.example.com"))["command"]
    authorization = descriptor.redact(base.merge(command: "curl -H 'Authorization: Bearer abcdefghijklmnop' https://api.example.com"))["command"]
    url = descriptor.redact(base.merge(command: "curl https://deploy:hunter2@api.example.com"))["command"]

    expect(password).to include("--password=[redacted]")
    expect(password).not_to include("hunter2")
    expect(authorization).to include("Bearer [redacted]")
    expect(authorization).not_to include("abcdefghijklmnop")
    expect(url).to include("deploy:[redacted]@")
    expect(url).not_to include("hunter2")

    expect {
      descriptor.redact(base.merge(command: "sk-abcdefghijklmnopqrstuvwxyz"))
    }.to raise_error(Mcp::Tools::AuthorizationSupport::AuthorizationError, /cannot be represented safely/)
  end

  it "creates exact chat and permanent approvals that do not cross commands, destinations, or classifications" do
    owner = Factories.user
    chat = ChatSession.create!(user: owner, title: "SSH approval")
    context = McpToolContext.from_chat_session(chat)
    descriptor = described_class.capability_descriptor("ssh.execute/risky@v1")
    arguments = {
      credential: "production", host: "api.example.com", user: "deploy", port: 22,
      command: "uname -a", allow_risky_command: false, allow_unconstrained_host: false
    }

    result = Permissions::AuthorizationRequest.new(
      context:, descriptor:, arguments:, purpose: "Inspect the host",
      action: "authorized_tool_call", payload: { "tool_name" => "credential_store_ssh_exec", "arguments" => arguments.stringify_keys }
    ).call
    request = result.request
    item = request.authorization_items.sole
    options = Permissions::SmartDecision.new(request:, item:, user: owner).options

    expect(item).to have_attributes(
      operation: "ssh.execute/read", risk: "high",
      requested_durations: %w[invocation chat_session permanent]
    )
    expect(item.resource_scope).to eq(
      "credential" => "production", "host" => "api.example.com", "user" => "deploy", "port" => 22
    )
    expect(item.normalized_arguments).to include(
      "credential_name" => "production", "command" => "uname -a",
      "command_sha256" => Digest::SHA256.hexdigest("uname -a")
    )
    expect(options.pluck(:kind, :duration)).to eq([
      [ "allow_chat", "chat_session" ],
      [ "always_allow_command", "permanent" ]
    ])

    preview = Permissions::RuleDraft.from_request_item(user: owner, request:, item:, duration: "permanent").preview
    rule = preview.valid? && preview.then { Permissions::SmartDecision.new(request:, item:, user: owner).apply_rule!(duration: "permanent", digest: preview.digest) }
    expect(rule).to be_a(PermissionRule)

    authorize = lambda do |candidate|
      Permissions::Management.new(owner).explain(
        descriptor:, role: context.role, resource_scope: candidate, arguments: candidate,
        context: { user: owner, subject_selector_type: "interactive_chat", chat_session_id: chat.id }
      ).policy
    end
    expect(authorize.call(arguments)).to eq(:allow)
    expect(authorize.call(arguments.merge(command: "id"))).to eq(:ask)
    expect(authorize.call(arguments.merge(host: "other.example.com"))).to eq(:ask)
    expect(authorize.call(arguments.merge(command: "sudo id"))).to eq(:ask)

    rule.revoke!(actor: owner)
    expect(authorize.call(arguments)).to eq(:ask)
  end
end
