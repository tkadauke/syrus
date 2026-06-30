require "rails_helper"
require "tmpdir"

RSpec.describe AgentEnvironmentSnapshot do
  around do |example|
    Dir.mktmpdir("syrus-agent-env") do |dir|
      @workspace_path = Pathname.new(dir)
      example.run
    end
  end

  describe ".for_run" do
    it "renders repository, workflow, tool, prepare, grader, and package-script context" do
      repo = repository(owner: "rome", name: "aqueduct", default_branch: "main")
      job = Factories.job(repository: repo)
      workflow = job.workflows.last
      step = workflow.steps.find_by!(kind: "implement")
      run = step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: "codex", iteration: 2)

      @workspace_path.join(".syrus.yml").write(<<~YAML)
        prepare:
          - bundle install
        grade:
          - name: rspec
            run: bin/rspec
      YAML
      @workspace_path.join("package.json").write(JSON.generate("scripts" => { "test" => "vitest", "build" => "vite build" }))

      snapshot = described_class.for_run(run, workspace_path: @workspace_path)

      expect(snapshot).to include("Agent environment snapshot:")
      expect(snapshot).to include("Repository: rome/aqueduct")
      expect(snapshot).to include("Workflow: ##{workflow.id} trigger=initial")
      expect(snapshot).to include("Step/Run: implement step ##{step.id}, run ##{run.id}, iteration 2")
      expect(snapshot).to include("Agent provider: codex")
      expect(snapshot).to include("MCP/tools: run sidecar `syrus-mcp-sidecar` is configured with `submit_summary` and `submit_test_plan`")
      expect(snapshot).to include("Prepare plan: .syrus.yml: bundle install")
      expect(snapshot).to include('Graders: .syrus.yml: rspec="bin/rspec" (required)')
      expect(snapshot).to include('Package scripts: test="vitest"; build="vite build"')
      expect(snapshot).to include("`git fetch` is allowed")
    end
  end

  describe ".for_chat" do
    it "renders attached repository paths and chat MCP tool groups" do
      repo = repository(owner: "rome", name: "forums", default_branch: "trunk")
      chat = ChatSession.create!(user: repo.user, repository: repo)

      snapshot = described_class.for_chat(repository: repo, chat_session: chat)

      expect(snapshot).to include("Chat: ##{chat.id} scoped to rome/forums")
      expect(snapshot).to include("no commit, push, or PR-opening tool is available in chat")
      expect(snapshot).to include("attached checkouts under `/syrus-home/.syrus/chat-workspaces/*/repositories/` are read-only")
      expect(snapshot).to include("never use Write, Edit, or Bash to create, modify, delete, rename, move, format, or generate files there")
      expect(snapshot).to include("Do not write memory to the filesystem")
      expect(snapshot).to include("use the Syrus memory MCP tools instead")
      expect(snapshot).not_to include("MEMORY.md")
      expect(snapshot).not_to include("chat memory directory")
      expect(snapshot).to include('checkout=not cloned; call `attach_repository("rome/forums")`')
      expect(snapshot).to include("live Syrus state: list_chats, list_jobs, read_job, read_pr")
      expect(snapshot).to include("whiteboard: read_scene, draw_shape")
      expect(snapshot).to include("save_canvas, clear_canvas")
    end

    it "renders confirmed proposal activity with canonical Syrus IDs" do
      repo = repository(owner: "rome", name: "forums")
      chat = ChatSession.create!(user: repo.user, repository: repo)
      epic = Factories.epic(user: repo.user, repository: repo, title: "Rebuild the forum")
      child_job = Factories.job_record(user: repo.user, repository: repo, issue_title: "Add arches")
      epic_proposal = chat.proposals.create!(
        repository: repo,
        epic: epic,
        state: "confirmed",
        slug: "forum",
        title: "Rebuild the forum",
        body: "Do it.",
        kind: "epic"
      )
      chat.proposals.create!(
        repository: repo,
        parent_proposal: epic_proposal,
        job: child_job,
        state: "confirmed",
        slug: "add-arches",
        title: "Add arches",
        body: "Do it.",
        kind: "job"
      )

      snapshot = described_class.for_chat(repository: repo, chat_session: chat)

      expect(snapshot).to include("Recent proposal activity:")
      expect(snapshot).to include(%(- EPIC-#{epic.id} "Rebuild the forum" confirmed with jobs: JOB-#{child_job.id} "Add arches" (proposal slug: forum)))
      expect(snapshot).to include(%(- JOB-#{child_job.id} "Add arches" confirmed (proposal slug: add-arches)))
    end

    it "renders developer elaboration Epic context for backlog Epics with no Jobs" do
      repo = repository(owner: "rome", name: "forums")
      repo.user.update!(role: "developer")
      epic = Factories.epic(
        user: repo.user,
        repository: repo,
        title: "Plan forum restoration",
        description: "Restore forum posting without choosing tables yet.",
        state: "backlog"
      )
      chat = ChatSession.create!(user: repo.user, repository: repo)
      chat.messages.create!(role: "user", content: { "text" => "Elaborate EPIC-#{epic.id}" })

      snapshot = described_class.for_chat(repository: repo, chat_session: chat)

      expect(snapshot).to include("Developer elaboration mode: active for #{epic.display_number}")
      expect(snapshot).to include("Elaboration Epic title: Plan forum restoration")
      expect(snapshot).to include("Elaboration Epic description: Restore forum posting")
    end

    it "activates elaboration from a read_epic result with no child Jobs" do
      repo = repository(owner: "rome", name: "forums")
      epic = Factories.epic(user: repo.user, repository: repo, title: "PO backlog", state: "backlog")
      chat = ChatSession.create!(user: repo.user, repository: repo)
      chat.messages.create!(role: "user", content: { "text" => "Read this Epic first." })
      chat.messages.create!(
        role: "tool_result",
        tool_name: "read_epic",
        content: {
          "result" => [
            {
              "type" => "text",
              "text" => JSON.generate("epic" => { "id" => epic.id, "state" => "backlog" }, "child_jobs" => [])
            }
          ]
        }
      )

      snapshot = described_class.for_chat(repository: repo, chat_session: chat)

      expect(snapshot).to include("Developer elaboration mode: active for #{epic.display_number}")
    end
  end

  describe "#apply_to" do
    it "does not duplicate an existing snapshot block" do
      snapshot = described_class.new(repository: repository, chat_session: nil)
      prompt = "Agent environment snapshot:\n- already here\n\nTask body"

      expect(snapshot.apply_to(prompt)).to eq(prompt)
    end
  end
end
