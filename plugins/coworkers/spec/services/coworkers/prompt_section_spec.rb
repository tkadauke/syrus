require "rails_helper"

RSpec.describe Coworkers::PromptSection do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url)
  end
  let(:chat) { ChatSession.create!(user: owner, repository: repository, title: "Maya") }
  let(:scope) { Syrus::EffectScope.new(label: "coworker prompt spec") }

  around do |example|
    Dir.mktmpdir do |dir|
      @root = Pathname(dir)
      example.run
    end
  end

  before do
    Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: "main")
    Coworkers::ChatExtension.install_into(scope)
    allow(ChatWorkspace).to receive(:repo_path_for).with(chat, repository).and_return(@root)
  end

  after { scope.dispose }

  it "loads the three identity files under the cap into fresh and resumed prompts" do
    described_class::FILES.each { |name| @root.join(name).write("content from #{name}\n") }
    allow(Syrus::PluginRegistry).to receive(:providers_for).and_call_original
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:chat_prompt_injector).and_return([ described_class ])

    fresh = Prompts::ChatSystem.new(repository: repository, chat_session: chat).to_s
    resumed = Prompts::ChatSystem.new(repository: repository, chat_session: chat).elaboration_guidance

    described_class::FILES.each do |name|
      expect(fresh).to include(name, "content from #{name}")
      expect(resumed).to include(name, "content from #{name}")
    end
  end

  it "keeps ordinary planning guidance from overriding coworker workspace access" do
    prompt = Prompts::ChatSystem.new(repository: repository, chat_session: chat).to_s

    expect(prompt).to include("`write_coworker_file`", "Attached product repositories are read-only")
    expect(prompt).to include("Syrus commits and pushes")
    expect(prompt).to include("coworker file tools create, edit, move, and delete")
    expect(prompt).not_to include("you're the planning surface")
    expect(prompt).not_to include("The workspace is isolated. Nothing you do is ever pushed")
    expect(prompt).not_to include("The durable products of this session are proposals")
  end

  it "loads today and yesterday, participant and sender people files, and the attached repository file" do
    participant = Factories.user
    sender = Factories.user
    ChatParticipant.create!(chat_session: chat, user: participant, role: "member")
    message = chat.messages.build(role: "user", sender_user: sender, content: { "text" => "hello" })

    travel_to(Time.zone.parse("2026-10-29 12:00:00")) do
      expected = {
        "memory/daily/2026-10-29.md" => "today",
        "memory/daily/2026-10-28.md" => "yesterday",
        "memory/people/#{owner.handle}.md" => "owner notes",
        "memory/people/#{participant.handle}.md" => "participant notes",
        "memory/people/#{sender.handle}.md" => "sender notes",
        "memory/repos/#{repository.owner}__#{repository.name}.md" => "repository notes"
      }
      expected.each do |name, content|
        path = @root.join(name)
        path.dirname.mkpath
        path.write(content)
      end

      section = described_class.chat_prompt_section(chat_session: chat, repository: repository, message: message)

      expected.each { |name, content| expect(section).to include(name, content) }
    end
  end

  it "ignores missing files, including a participant without a people file" do
    participant = Factories.user
    ChatParticipant.create!(chat_session: chat, user: participant, role: "member")
    @root.join("SOUL.md").write("still present")

    section = described_class.chat_prompt_section(chat_session: chat, repository: repository)

    expect(section).to include("still present")
    expect(section).not_to include("memory/people/#{participant.handle}.md")
  end

  it "keeps superseded memory on disk but omits it from standing context" do
    path = @root.join("memory/daily/#{Time.zone.today.iso8601}.md")
    path.dirname.mkpath
    obsolete = "~~Use the old endpoint~~ (superseded 2026-11-03 by JOB-42: replaced)"
    path.write("Current decision\n#{obsolete}\n")

    section = described_class.chat_prompt_section(chat_session: chat, repository: repository)

    expect(section).to include("Current decision")
    expect(section).not_to include("Use the old endpoint")
    expect(path.read).to include(obsolete)
  end

  it "still describes requestable tool grants when every context file is missing" do
    section = described_class.chat_prompt_section(chat_session: chat, repository: repository)

    expect(section).to include("### Permissions", "not held")
  end

  it "privately supplies both conflicted sides without creating an owner-facing message" do
    @root.join("USER.md").write("<<<<<<< HEAD\nowner preference\n=======\ncoworker preference\n>>>>>>> home\n")
    Coworkers::WorkspaceConflict.create!(chat_session: chat, repository:, source_branch: "coworkers/chat/source",
      files: [ "USER.md" ], versions: { "USER.md" => @root.join("USER.md").read }, detail: "merge failed",
      expires_at: 1.hour.from_now)

    section = described_class.chat_prompt_section(chat_session: chat, repository: repository)

    expect(section).to include("Private workspace conflict recovery", "owner preference", "coworker preference")
    expect(section).to include("without mentioning the conflict to the owner", "Preserve the intent of both sides")
    expect(chat.messages).to be_empty
  end

  it "does not follow a conflict symlink outside the workspace" do
    outside = @root.dirname.join("prompt-secret")
    outside.write("worker credential material")
    File.symlink(outside, @root.join("USER.md"))
    Coworkers::WorkspaceConflict.create!(chat_session: chat, repository:, source_branch: "coworkers/chat/source",
      files: [ "USER.md" ], versions: { "USER.md" => nil }, detail: "merge failed", expires_at: 1.hour.from_now)

    section = described_class.chat_prompt_section(chat_session: chat, repository: repository)

    expect(section).to include("Private workspace conflict recovery", "USER.md")
    expect(section).not_to include("worker credential material")
  end

  it "lists held policy and scope alongside missing catalog grants" do
    descriptor = Coworkers::GrantCatalog::Descriptor.new(
      name: "database.read", label: "Read database", description: "Read it", default_policy: "confirm", maximum_policy: "auto",
      tools: [ "list_database_tables" ], scope_options_callback: ->(user:) { [ user.id ] },
      scope_label_callback: ->(value) { "Connection #{value}" }, valid_scope_callback: ->(value, user:) { value == user.id }
    )
    allow(Coworkers::GrantCatalog).to receive(:all).and_return([ descriptor ])
    PermissionRule.create!(owner_user: owner, created_by_user: owner, updated_by_user: owner,
      subject_selector_type: "agent", subject_selector_id: coworker.id.to_s, subject_role_keys: [],
      capability: "database.read@v1", operation: "database.read/list_database_tables@v1",
      resource_type: "database", resource_scope: { "connection_id" => owner.id }, constraints: {},
      policy: "ask", policy_layer: "agent", source: "coworker_permission", provenance: {}, delegable: false)

    section = described_class.chat_prompt_section(chat_session: chat, repository: repository)

    expect(section).to include("`database.read` — confirm by canonical permission rule")
    expect(section).to include("tools: list_database_tables")
    expect(section).not_to include("not held")
  end

  it "caps each file and the total context with visible markers" do
    described_class::FILES.each do |name|
      @root.join(name).binwrite("x" * (described_class::MAX_FILE_BYTES + 1))
    end

    section = described_class.chat_prompt_section(chat_session: chat, repository: repository)

    expect(section).to include(described_class::TRUNCATION_MARKER)
    expect(section.bytesize).to be <= described_class::MAX_TOTAL_BYTES
  end

  it "counts headings and separators against the aggregate cap" do
    people = 5_000.times.map { |index| instance_double(User, handle: "person-#{index.to_s.rjust(4, "0")}") }
    allow(chat).to receive(:participants).and_return(people)
    people.each do |person|
      path = @root.join("memory/people/#{person.handle}.md")
      path.dirname.mkpath
      path.write("")
    end

    section = described_class.chat_prompt_section(chat_session: chat, repository: repository)

    expect(section.bytesize).to be <= described_class::MAX_TOTAL_BYTES
    expect(section).to end_with(described_class::TRUNCATION_MARKER)
  end
end
