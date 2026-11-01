require "rails_helper"

RSpec.describe CredentialStore::PermissionProvider do
  it "classifies read-only diagnostics separately while keeping risky SSH exact-invocation only" do
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
      maximum_autonomy: :invocation, authority_durations: [ :invocation ]
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

  it "scopes authority to the credential and exact SSH destination" do
    schema = described_class.permission_resource_scopes.fetch(:ssh_destination)
    context = {}
    destination = schema.normalize(
      { credential: "production", host: "API.EXAMPLE.COM", user: "deploy", port: "2222" }, context:
    )

    expect(destination).to have_attributes(status: :ok)
    expect(destination.value).to eq(
      "credential" => "production", "host" => "api.example.com", "user" => "deploy", "port" => 2222
    )
    expect(schema.normalize({ credential: "production", host: "api.example.com" }, context:))
      .to have_attributes(status: :invalid, errors: include("user is required"))
    expect(schema.normalize({ credential: "production", host: "api.example.com", user: "deploy", port: "invalid" }, context:))
      .to have_attributes(status: :invalid, errors: include("port must be between 1 and 65535"))
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
    expect(descriptor.redact(arguments)).to include("credential" => "[REDACTED CREDENTIAL]")
    expect(Permissions::InvocationFingerprint.call(descriptor:, arguments:)).not_to eq(changed_command)
    expect(Permissions::InvocationFingerprint.call(descriptor:, arguments:)).not_to eq(changed_destination)
  end
end
