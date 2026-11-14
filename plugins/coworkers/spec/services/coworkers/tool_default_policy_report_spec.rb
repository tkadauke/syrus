require "rails_helper"

RSpec.describe Coworkers::ToolDefaultPolicyReport do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-report", workspace_repo: repository.remote_url)
  end
  let(:chat) { ChatSession.create!(user: owner, repository: repository, title: "Maya") }
  let(:scope) { Syrus::EffectScope.new(label: "default policy report spec") }

  before do
    Coworkers::Chat.create!(coworker:, chat_session: chat, role: "main")
    Coworkers::ChatExtension.install_into(scope)
    chat.association(:coworker_chat).reset
  end

  after { scope.dispose }

  subject(:report) { described_class.new(chat_session: chat) }

  def group(policy) = report.grouped.fetch(policy).map(&:tool)

  it "satisfies every invariant for the complete shipped catalog" do
    expect(report.findings).to eq([])
    expect(report.validate!).to be(true)
  end

  it "covers every core coworker registration and every coworker-safe plugin definition" do
    core_names = McpToolRegistry.entries(surface: :coworker).map(&:tool_name)
    plugin_names = Mcp::CoworkerToolCatalog.all(chat_session: chat).reject { |entry| entry.provider.nil? }.select(&:definition).map(&:tool_name)

    expect(report.rows.map(&:tool)).to include(*core_names, *plugin_names)
    expect(report.rows.map(&:tool)).to eq(report.rows.map(&:tool).uniq)
    expect(report.rows.select { |row| row.source == "core" }.map(&:tool)).to match_array(core_names)
    expect(report.rows.reject { |row| row.source == "core" }.map(&:tool)).to match_array(plugin_names)
    report.rows.each do |row|
      expect(row.reason).to be_present
      expect(row.effects).not_to be_empty
    end
  end

  it "defaults fully benign tools to allow" do
    expect(group(:allow)).to include(
      "attach_repository", "detach_repository", "list_repository_files", "read_repository_file", "search_repository_code",
      "get_job_diff", "read_pr", "list_jobs", "search_jobs", "read_job", "propose_job", "propose_epic_with_jobs",
      "write_coworker_file", "edit_coworker_file", "move_coworker_file", "delete_coworker_file",
      "ask_user_question", "suggest_next_step", "discover_coworker_capabilities", "reply_in_chat_thread",
      "request_permission", "surrender_permission_lease", "request_permission_revocation"
    )
  end

  it "allows memory reads while keeping inherited memory mutations gated" do
    memory = report.rows.select { |row| row.source == "AgentMemory::ChatToolSet" }.map(&:tool)

    reads = %w[read_memory search_memories list_memories]
    mutations = %w[write_memory delete_memory publish_memory unpublish_memory]
    expect(memory).to match_array(reads + mutations)
    expect(group(:allow)).to include(*reads)
    expect(group(:ask)).to include(*mutations)
  end

  it "keeps confidential, operational, communicating, scheduling, and spawning tools gated" do
    expect(group(:ask)).to include(
      "list_chats", "search_chats", "read_chat_messages",
        "read_backend_exception_events", "read_browser_error_events", "read_performance_log_events",
      "message_coworker", "manage_coworker_schedule", "spawn_coworker_chat", "read_syrus_logs", "read_performance_diagnostics"
    )
    expect(group(:allow)).not_to include("message_coworker", "manage_coworker_schedule", "spawn_coworker_chat", "list_chats")
  end

  it "never allows database, Kubernetes, or credential-using tools by default" do
    gated = report.rows.select { |row| row.effects.include?(:credential_use) || row.tool.start_with?("mysql_db_browser_", "k8s_cluster_") }

    expect(gated).not_to be_empty
    expect(gated.map(&:default).uniq - %i[ask deny]).to eq([])
  end

  it "never allows a tool with an effect outside the benign set" do
    report.grouped.fetch(:allow).each do |row|
      risky = row.effects - Permissions::CoworkerDefaultPolicy::SAFE_EFFECTS - [ :internal_write ]
      expect(risky).to eq([]), "#{row.tool} allows #{risky.join(', ')}"
      expect(row.risk).to eq(:low)
    end
  end

  it "keeps proposals as pending operator-confirmed drafts with no confirmation authority" do
    %w[propose_job propose_epic_with_jobs].each do |name|
      entry = McpToolRegistry.entries(surface: :coworker).find { |candidate| candidate.tool_name == name }
      descriptor = entry.descriptor
      expect(entry.approval_effect).to eq(true)
      expect(descriptor.benign_internal).to eq(:draft_proposal)
      expect(descriptor.maximum_autonomy).to eq(:invocation)
    end
    expect(report.rows.map(&:tool)).not_to include("confirm_proposal", "confirm_job_proposal")
  end

  it "reports a grant whose advertised policy disagrees with the effective descriptor default" do
    grant = Coworkers::GrantCatalog::Descriptor.new(
      name: "code.read", label: "x", description: "x", default_policy: "confirm", maximum_policy: "auto",
      tools: [ "read_repository_file" ], scope_options_callback: nil, scope_label_callback: nil, valid_scope_callback: nil
    )
    contradictory = described_class.new(chat_session: chat, grants: [ grant ])

    expect(contradictory.findings).to include(match(/read_repository_file: grant code\.read advertises confirm.*effective default is allow/))
    expect { contradictory.validate! }.to raise_error(ArgumentError, /invariants failed/)
  end

  it "reports an unsafe allow default in a plugin definition" do
    unsafe = Permissions::CapabilityDescriptor.new(
      capability: "spec.unsafe@v1", operation: "spec.unsafe/send@v1", effects: %i[communication], risk: :medium,
      requestable_roles: Permissions::CoworkerDefaultPolicy::ROLES,
      defaults: Permissions::CoworkerDefaultPolicy::ROLES.index_with { :allow },
      maximum_autonomy: :invocation, authority_durations: [ :invocation ], resource_scope: { type: :none },
      classifier: ->(_arguments) { {} }, fingerprint_normalizer: ->(arguments) { arguments }, redactor: ->(arguments) { arguments }
    )
    entry = Mcp::CoworkerToolCatalog::Descriptor.new(tool_name: "send_unsafe", capability: "spec.unsafe", ungated: false, tier: :essential,
      tool: nil, provider: Class.new, definition: { name: "send_unsafe", capability_descriptor: unsafe })

    findings = described_class.new(catalog: [ entry ], grants: []).findings

    expect(findings).to contain_exactly(match(/send_unsafe: .*defaults to allow.*not fully benign/), match(/send_unsafe: .*defaults to allow.*not fully benign/))
  end

  it "reports coworker roles that disagree on the default" do
    split = Permissions::CapabilityDescriptor.new(
      capability: "spec.split@v1", operation: "spec.split/read@v1", effects: %i[local_read], risk: :low,
      requestable_roles: Permissions::CoworkerDefaultPolicy::ROLES,
      defaults: { AgentRole::COWORKER_CHAT => :allow, AgentRole::COWORKER => :ask },
      maximum_autonomy: :permanent, authority_durations: [ :invocation ], resource_scope: { type: :none },
      classifier: ->(_arguments) { {} }, fingerprint_normalizer: ->(arguments) { arguments }, redactor: ->(arguments) { arguments }
    )
    entry = Mcp::CoworkerToolCatalog::Descriptor.new(tool_name: "split_read", capability: "spec.split", ungated: false, tier: :essential,
      tool: nil, provider: Class.new, definition: { name: "split_read", capability_descriptor: split })

    expect(described_class.new(catalog: [ entry ], grants: []).findings).to include(match(/roles disagree/))
  end

  it "renders a grouped text report and JSON" do
    expect(report.to_text).to match(/\AALLOW \(\d+\)\n.*ASK \(\d+\)\n.*DENY \(\d+\)/m)
    json = report.as_json
    expect(json.fetch(:groups).keys).to eq(%i[allow ask deny])
    expect(json.fetch(:groups).fetch(:allow).first).to include(:tool, :reason, :effects, :risk, :operation, :maximum_autonomy)
    expect(json.fetch(:findings)).to eq([])
  end

  it "keeps the legacy default grants aligned with the effective descriptor defaults" do
    expect(Coworkers::Create::DEFAULT_GRANTS).to include("chats.read_shared" => "confirm", "syrus.propose_job" => "auto", "syrus.read_jobs" => "auto")
  end
end
