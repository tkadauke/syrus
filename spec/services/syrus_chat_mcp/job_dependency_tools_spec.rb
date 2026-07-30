require "rails_helper"

RSpec.describe "SyrusChatMcp job dependency tools" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [
        SyrusChatMcp::AddJobDependencyTool,
        SyrusChatMcp::RemoveJobDependencyTool
      ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(name, arguments = {})
    raw = server.handle_json({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: name, arguments: arguments }
    }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload(response)
    JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
  end

  def error_text(response)
    response.dig(:result, :content, 0, :text)
  end

  describe "add_job_dependency" do
    it "creates a JobDependency and returns the updated dependency ids" do
      job = Factories.job_record(user: user, repository: repository)
      prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 43)

      response = call_tool("add_job_dependency", job_id: job.id, depends_on_job_id: prerequisite.id)

      expect(response.dig(:result, :isError)).to be_falsey
      expect(payload(response)).to include(job_id: job.id, depends_on_job_ids: [ prerequisite.id ], depends_on_epic_ids: [])
      expect(job.reload.depends_on_jobs).to contain_exactly(prerequisite)

      dependency = job.dependencies.sole
      expect(dependency).to have_attributes(source: "manual", created_by_user: user)
    end

    it "is idempotent when the dependency already exists" do
      job = Factories.job_record(user: user, repository: repository)
      prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 43)

      2.times do
        response = call_tool("add_job_dependency", job_id: job.id, depends_on_job_id: prerequisite.id)

        expect(response.dig(:result, :isError)).to be_falsey
        expect(payload(response)).to include(job_id: job.id, depends_on_job_ids: [ prerequisite.id ])
      end

      expect(job.reload.dependencies.count).to eq(1)
    end

    it "rejects self references" do
      job = Factories.job_record(user: user, repository: repository)

      response = call_tool("add_job_dependency", job_id: job.id, depends_on_job_id: job.id)

      expect(response.dig(:result, :isError)).to be true
      expect(error_text(response)).to include("can't be the same Job")
      expect(job.reload.dependencies).to be_empty
    end

    it "rejects dependencies that would create a cycle" do
      root = Factories.job_record(user: user, repository: repository)
      leaf = Factories.job_record(user: user, repository: repository, issue_number: 43)
      JobDependency.create!(job: leaf, depends_on_job: root, source: "manual", created_by_user: user)

      response = call_tool("add_job_dependency", job_id: root.id, depends_on_job_id: leaf.id)

      expect(response.dig(:result, :isError)).to be true
      expect(error_text(response)).to match(/cycle/)
      expect(root.reload.dependencies).to be_empty
    end

    it "rejects cross-user Jobs" do
      job = Factories.job_record(user: user, repository: repository)
      other_user = Factories.user
      other_job = Factories.job_record(user: other_user, repository: Factories.repository(user: other_user))

      response = call_tool("add_job_dependency", job_id: job.id, depends_on_job_id: other_job.id)

      expect(response.dig(:result, :isError)).to be true
      expect(error_text(response)).to include("job not found")
      expect(job.reload.dependencies).to be_empty
    end

    it "creates a JobDependency pointing at an Epic" do
      job = Factories.job_record(user: user, repository: repository)
      epic = Factories.epic(repository: repository)

      response = call_tool("add_job_dependency", job_id: job.id, depends_on_epic_id: epic.id)

      expect(response.dig(:result, :isError)).to be_falsey
      expect(payload(response)).to include(job_id: job.id, depends_on_job_ids: [], depends_on_epic_ids: [ epic.id ])

      dependency = job.reload.dependencies.sole
      expect(dependency).to have_attributes(depends_on_epic: epic, source: "manual", created_by_user: user)
    end

    it "is idempotent when the epic dependency already exists" do
      job = Factories.job_record(user: user, repository: repository)
      epic = Factories.epic(repository: repository)

      2.times do
        response = call_tool("add_job_dependency", job_id: job.id, depends_on_epic_id: epic.id)
        expect(response.dig(:result, :isError)).to be_falsey
      end

      expect(job.reload.dependencies.count).to eq(1)
    end

    it "rejects cross-user Epics" do
      job = Factories.job_record(user: user, repository: repository)
      other_user = Factories.user
      other_repo = Factories.repository(user: other_user)
      other_epic = Factories.epic(repository: other_repo)

      response = call_tool("add_job_dependency", job_id: job.id, depends_on_epic_id: other_epic.id)

      expect(response.dig(:result, :isError)).to be true
      expect(error_text(response)).to include("epic not found")
      expect(job.reload.dependencies).to be_empty
    end

    it "errors when neither target param is supplied" do
      job = Factories.job_record(user: user, repository: repository)

      response = call_tool("add_job_dependency", job_id: job.id)

      expect(response.dig(:result, :isError)).to be true
      expect(error_text(response)).to include("exactly one of depends_on_job_id or depends_on_epic_id")
    end

    it "errors when both target params are supplied" do
      job = Factories.job_record(user: user, repository: repository)
      prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 43)
      epic = Factories.epic(repository: repository)

      response = call_tool("add_job_dependency", job_id: job.id, depends_on_job_id: prerequisite.id, depends_on_epic_id: epic.id)

      expect(response.dig(:result, :isError)).to be true
      expect(error_text(response)).to include("exactly one of depends_on_job_id or depends_on_epic_id")
    end
  end

  describe "remove_job_dependency" do
    it "destroys an existing JobDependency" do
      job = Factories.job_record(user: user, repository: repository)
      prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 43)
      JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual", created_by_user: user)

      response = call_tool("remove_job_dependency", job_id: job.id, depends_on_job_id: prerequisite.id)

      expect(response.dig(:result, :isError)).to be_falsey
      expect(payload(response)).to include(job_id: job.id, depends_on_job_ids: [], depends_on_epic_ids: [])
      expect(job.reload.depends_on_jobs).to be_empty
    end

    it "is idempotent when the dependency row does not exist" do
      job = Factories.job_record(user: user, repository: repository)
      prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 43)

      2.times do
        response = call_tool("remove_job_dependency", job_id: job.id, depends_on_job_id: prerequisite.id)

        expect(response.dig(:result, :isError)).to be_falsey
        expect(payload(response)).to include(job_id: job.id, depends_on_job_ids: [])
      end
    end

    it "destroys an existing epic JobDependency" do
      job = Factories.job_record(user: user, repository: repository)
      epic = Factories.epic(repository: repository)
      JobDependency.create!(job: job, depends_on_epic: epic, source: "manual", created_by_user: user)

      response = call_tool("remove_job_dependency", job_id: job.id, depends_on_epic_id: epic.id)

      expect(response.dig(:result, :isError)).to be_falsey
      expect(payload(response)).to include(job_id: job.id, depends_on_job_ids: [], depends_on_epic_ids: [])
      expect(job.reload.dependencies).to be_empty
    end

    it "is idempotent when the epic dependency row does not exist" do
      job = Factories.job_record(user: user, repository: repository)
      epic = Factories.epic(repository: repository)

      2.times do
        response = call_tool("remove_job_dependency", job_id: job.id, depends_on_epic_id: epic.id)

        expect(response.dig(:result, :isError)).to be_falsey
        expect(payload(response)).to include(job_id: job.id, depends_on_epic_ids: [])
      end
    end

    it "errors when neither target param is supplied" do
      job = Factories.job_record(user: user, repository: repository)

      response = call_tool("remove_job_dependency", job_id: job.id)

      expect(response.dig(:result, :isError)).to be true
      expect(error_text(response)).to include("exactly one of depends_on_job_id or depends_on_epic_id")
    end

    it "errors when both target params are supplied" do
      job = Factories.job_record(user: user, repository: repository)
      prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 43)
      epic = Factories.epic(repository: repository)

      response = call_tool("remove_job_dependency", job_id: job.id, depends_on_job_id: prerequisite.id, depends_on_epic_id: epic.id)

      expect(response.dig(:result, :isError)).to be true
      expect(error_text(response)).to include("exactly one of depends_on_job_id or depends_on_epic_id")
    end
  end
end
