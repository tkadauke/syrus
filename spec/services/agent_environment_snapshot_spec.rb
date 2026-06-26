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
      expect(snapshot).to include("only your own non-repository chat memory directory may be written")
      expect(snapshot).to include('checkout=not cloned; call `attach_repository("rome/forums")`')
      expect(snapshot).to include("live Syrus state: list_chats, list_jobs, read_job, read_pr")
      expect(snapshot).to include("whiteboard: read_scene, draw_shape")
      expect(snapshot).to include("save_canvas, clear_canvas")
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
