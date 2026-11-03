require "rails_helper"

RSpec.describe Permissions::LocalModeActions do
  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user, mode: "local") }
  let(:chat_entries) { McpToolRegistry.entries(surface: :chat).index_by(&:tool_name) }

  def authorize(tool, arguments, session: chat_session)
    Permissions::LocalModeAuthorization.authorize(chat_session: session, tool_name: tool, arguments: arguments)
  end

  def grant(tool, arguments, **options)
    Permissions::LocalModeAuthorization.grant_after_confirmation(chat_session: chat_session, tool_name: tool, arguments: arguments, **options)
  end

  before { chat_session.create_local_daemon_session!(user: user, auth_token: "tok", daemon_repo: "acme/app") }

  it "registers run_command and write_file with explicit local-host descriptors" do
    described_class.tool_names.each do |name|
      entry = chat_entries.fetch(name)

      expect(entry).to have_attributes(explicit_descriptor: true, compatibility_descriptor: false)
      expect(entry.descriptor).to have_attributes(
        capability: "syrus.local_mode@v1", maximum_autonomy: :chat_session,
        authority_durations: %i[invocation chat_session], defaults: { AgentRole::CHAT_LOCAL => :ask }
      )
      expect(entry.descriptor.effects).to eq(%i[operator_host_access])
    end
    findings = Permissions::CapabilityRegistryValidator.for_application.findings
    expect(findings.select { |f| f.registrations.any? { |r| described_class.covers?(r.tool_name) } }).to be_empty
  end

  describe "classification" do
    def effects(command) = described_class.classify("run_command", command: command).effects

    it "keeps plain commands at host access only" do
      expect(effects("bundle exec rspec spec/models")).to eq(%i[operator_host_access])
      expect(described_class.session_eligible?("run_command", command: "bin/rails test")).to be(true)
    end

    it "adds network, credential, destructive, and privilege effects" do
      expect(effects("curl https://example.com")).to include(:network_read)
      expect(effects("git push origin main")).to include(:network_read, :external_write)
      expect(effects("cat ~/.ssh/id_rsa")).to include(:credential_use)
      expect(effects("printenv")).to include(:credential_use)
      expect(effects("rm -rf tmp")).to include(:destructive)
      expect(effects("sudo apt-get install foo")).to include(:privilege_change, :network_read)
      expect(described_class.classify("run_command", command: "rm -rf tmp").risk).to eq(:critical)
    end

    it "classifies sensitive and escaping file writes" do
      expect(described_class.classify("write_file", path: ".env", content: "").effects).to include(:credential_use)
      expect(described_class.classify("write_file", path: ".git/config", content: "").effects).to include(:destructive)
      expect(described_class.classify("write_file", path: "../x", content: "").effects).to include(:destructive)
      expect(described_class.classify("write_file", path: "/etc/passwd", content: "").effects).to include(:destructive)
      expect(described_class.session_eligible?("write_file", path: "app/a.rb", content: "x")).to be(true)
    end
  end

  describe "normalization" do
    it "treats surrounding whitespace and line endings as equal" do
      expect(described_class.normalize_arguments("run_command", command: "  ls\r\n")).to eq(described_class.normalize_arguments("run_command", "command" => "ls"))
    end

    it "normalizes paths and fingerprints content by digest" do
      a = described_class.normalize_arguments("write_file", path: "./app/../app/a.rb", content: "x")
      b = described_class.normalize_arguments("write_file", path: "app/a.rb", content: "x")

      expect(a).to eq(b)
      expect(a).not_to include("content")
      expect(a["path"]).to eq("app/a.rb")
      expect(described_class.normalize_arguments("write_file", path: "app/a.rb", content: "y")).not_to eq(a)
    end
  end

  describe "authority" do
    it "asks by default and covers the same normalized call for the chat session after confirmation" do
      expect(authorize("run_command", { command: "bin/test" })).not_to be_allowed

      lease = grant("run_command", { command: "bin/test" })

      expect(lease).to have_attributes(duration_kind: "chat_session", chat_session_id: chat_session.id, resource_scope: { "workspace" => "acme/app" })
      expect(authorize("run_command", { command: "  bin/test " })).to be_allowed
      expect(authorize("run_command", { command: "bin/test --verbose" })).not_to be_allowed
      expect(authorize("write_file", { path: "a.rb", content: "x" })).not_to be_allowed
    end

    it "does not grant session authority for network, credential, or destructive calls" do
      expect(grant("run_command", { command: "curl https://example.com" })).to be_nil
      expect(grant("run_command", { command: "rm -rf build" })).to be_nil
      expect(grant("write_file", { path: ".env", content: "A=1" })).to be_nil
      expect(authorize("run_command", { command: "rm -rf build" })).not_to be_allowed
      expect(PermissionLease.count).to eq(0)
    end

    it "grants nothing when the confirmation was exact-invocation only" do
      expect(grant("run_command", { command: "bin/test" }, duration: :invocation)).to be_nil
      expect(authorize("run_command", { command: "bin/test" })).not_to be_allowed
    end

    it "does not cross chat sessions or workspaces" do
      grant("run_command", { command: "bin/test" })
      other = ChatSession.create!(user: user, mode: "local")
      other.create_local_daemon_session!(user: user, auth_token: "other", daemon_repo: "acme/app")
      expect(authorize("run_command", { command: "bin/test" }, session: other)).not_to be_allowed

      chat_session.local_daemon_session.update!(daemon_repo: "acme/other")
      expect(authorize("run_command", { command: "bin/test" })).not_to be_allowed
    end

    it "stops covering the call once the lease is revoked" do
      lease = grant("run_command", { command: "bin/test" })
      expect(authorize("run_command", { command: "bin/test" })).to be_allowed

      lease.revoke!(actor: user)

      expect(authorize("run_command", { command: "bin/test" })).not_to be_allowed
    end

    it "is visible to the permissions hub" do
      lease = grant("write_file", { path: "a.rb", content: "x" })

      expect(Permissions::Management.new(user).leases).to include(lease)
    end

    it "honors a deny rule" do
      Permissions::Management.new(user).deny!(
        { "capability" => described_class::CAPABILITY, "operation" => described_class.operation_for("run_command"),
          "role" => AgentRole::CHAT_LOCAL, "subject_selector_type" => "local_chat" },
        actor: user
      )

      expect(authorize("run_command", { command: "ls" })).to be_denied
    end
  end
end
