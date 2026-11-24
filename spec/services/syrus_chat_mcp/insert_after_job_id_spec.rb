require "rails_helper"

RSpec.describe "insert_after_job_id proposals", :full_chat_access do
  let!(:_bootstrap_admin) { Factories.user(admin: true) }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }
  let(:epic) { Factories.epic(user: user, repository: repository) }
  let!(:a) { Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 1, state: "queued") }
  let!(:b) { Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 2, state: "queued") }

  before { JobDependency.create!(job: b, depends_on_job: a, source: "manual") }

  def call(tool, name, arguments)
    server = MCP::Server.new(name: "syrus-chat-sidecar", tools: [ tool ], server_context: { chat_session: chat_session })
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def text(response) = response.fetch(:result).fetch(:content).first.fetch(:text)

  describe Mcp::Tools::ProposeJobTool do
    def propose(**args)
      call(described_class, "propose_job", { repo: repository.slug, epic_id: epic.id, title: "Middle", description: "Body",
                                             planned_execution: { capabilities: { os: [ "linux" ] } } }.merge(args))
    end

    it "accepts a mid-chain insert and records the anchor and downstream Job" do
      response = propose(insert_after_job_id: a.id)

      expect(response[:result][:isError]).to be_falsey
      payload = JSON.parse(text(response), symbolize_names: true)
      expect(payload[:insertion]).to include(insert_after_slug: a.slug, insert_before_slug: b.slug)
      expect(chat_session.proposals.find_by!(title: "Middle").insert_after_job_id).to eq(a.id)
    end

    it "accepts an insert after the tail" do
      expect(propose(insert_after_job_id: b.id)[:result][:isError]).to be_falsey
    end

    it "rejects an anchor that is not in the Epic" do
      other = Factories.job_record(user: user, repository: repository, issue_number: 70)
      response = propose(insert_after_job_id: other.id)

      expect(response[:result][:isError]).to be(true)
      expect(text(response)).to include("not a Job in")
    end

    it "rejects combining it with explicit depends_on_job_ids" do
      response = propose(insert_after_job_id: a.id, depends_on_job_ids: [ a.id ])

      expect(response[:result][:isError]).to be(true)
      expect(text(response)).to include("cannot be combined")
    end

    it "requires epic_id" do
      response = call(described_class, "propose_job", { repo: repository.slug, title: "Middle", description: "Body", insert_after_job_id: a.id,
                                                          planned_execution: { capabilities: { os: [ "linux" ] } } })

      expect(response[:result][:isError]).to be(true)
      expect(text(response)).to include("requires epic_id")
    end

    it "rejects when the downstream Job is already executing" do
      b.update_columns(state: "running")
      response = propose(insert_after_job_id: a.id)

      expect(response[:result][:isError]).to be(true)
      expect(text(response)).to include("already started")
      expect(chat_session.proposals.find_by(title: "Middle")).to be_nil
    end
  end

  describe Mcp::Tools::ProposeEpicWithJobsTool do
    def jobs
      [
        { slug: "one", title: "One", description: "First." },
        { slug: "two", title: "Two", description: "Second." }
      ].map { |job| job.merge(planned_execution: { capabilities: { os: [ "linux" ] } }) }
    end

    def propose(epic_attrs: {}, jobs: self.jobs)
      call(described_class, "propose_epic_with_jobs", { epic: { slug: "card", epic_id: epic.id, description: "Existing work.", insert_after_job_id: a.id }.merge(epic_attrs), jobs: jobs })
    end

    it "accepts a mid-chain insert, defaulting the children to a chain" do
      response = propose

      expect(response[:result][:isError]).to be_falsey
      card = chat_session.proposals.find_by!(slug: "card")
      expect(card.insert_after_job_id).to eq(a.id)
      expect(card.insertion_json).to include(insert_after_slug: a.slug, insert_before_slug: b.slug)
      expect(chat_session.proposals.find_by!(slug: "two").dependencies.pluck(:slug)).to eq([ "one" ])
    end

    it "rejects an anchor outside the Epic" do
      other = Factories.job_record(user: user, repository: repository, issue_number: 70)
      response = propose(epic_attrs: { insert_after_job_id: other.id })

      expect(response[:result][:isError]).to be(true)
      expect(text(response)).to include("not a Job in")
    end

    it "rejects explicit dependencies on the first child" do
      with_dep = jobs
      with_dep[0][:depends_on_job_ids] = [ b.id ]
      response = propose(jobs: with_dep)

      expect(response[:result][:isError]).to be(true)
    end

    it "rejects when the downstream Job is already executing" do
      b.update_columns(state: "running")

      expect(propose[:result][:isError]).to be(true)
    end

    it "still rejects an append that does not chain onto the tail when the anchor is omitted" do
      response = propose(epic_attrs: { insert_after_job_id: nil })

      expect(response[:result][:isError]).to be(true)
    end
  end
end
