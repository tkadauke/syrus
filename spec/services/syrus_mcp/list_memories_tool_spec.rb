require "rails_helper"

RSpec.describe SyrusMcp::ListMemoriesTool do
  let(:run) { Factories.job.initial_run }
  let(:user) { run.job.user }
  let(:repository) { run.job.repository }

  def create_memory(owner: user, repo: repository, published: false, **attrs)
    ChatMemory.create!({
      user: owner,
      kind: "feedback",
      scope: "repository",
      scope_id: repo.id,
      content: "Default memory content.",
      published: published
    }.merge(attrs))
  end

  def call(context: { run_id: run.id }, **kwargs)
    described_class.call(**kwargs, server_context: context)
  end

  describe ".call" do
    it "lists memories within the job's repository" do
      memory = create_memory(content: "Always test.")

      response = call

      expect(response).not_to be_error
      payload = JSON.parse(response.content.first[:text])
      ids = payload["memories"].map { |m| m["id"] }
      expect(ids).to include(memory.id)
    end

    it "includes published memories from other users in the same repository" do
      other_user = Factories.user
      published_memory = create_memory(owner: other_user, content: "Shared convention.", published: true)

      response = call

      payload = JSON.parse(response.content.first[:text])
      ids = payload["memories"].map { |m| m["id"] }
      expect(ids).to include(published_memory.id)
    end

    it "excludes unpublished memories from other users" do
      other_user = Factories.user
      private_memory = create_memory(owner: other_user, published: false)

      response = call

      payload = JSON.parse(response.content.first[:text])
      ids = payload["memories"].map { |m| m["id"] }
      expect(ids).not_to include(private_memory.id)
    end

    it "excludes memories from other repositories" do
      other_repo = Factories.repository(user: user)
      other_memory = create_memory(repo: other_repo)

      response = call

      payload = JSON.parse(response.content.first[:text])
      ids = payload["memories"].map { |m| m["id"] }
      expect(ids).not_to include(other_memory.id)
    end

    it "excludes soft-deleted memories" do
      memory = create_memory
      memory.update!(deleted_at: Time.current)

      response = call

      payload = JSON.parse(response.content.first[:text])
      ids = payload["memories"].map { |m| m["id"] }
      expect(ids).not_to include(memory.id)
    end

    it "filters by kind" do
      feedback = create_memory(kind: "feedback")
      fact = create_memory(kind: "project_fact")

      response = call(kind: "project_fact")

      payload = JSON.parse(response.content.first[:text])
      ids = payload["memories"].map { |m| m["id"] }
      expect(ids).to include(fact.id)
      expect(ids).not_to include(feedback.id)
    end

    it "returns an error for an invalid kind" do
      response = call(kind: "not_a_kind")

      expect(response).to be_error
      expect(response.content.first[:text]).to include("kind must be one of")
    end

    it "returns an error for an invalid run context" do
      response = call(context: { run_id: 0 })

      expect(response).to be_error
      expect(response.content.first[:text]).to include("ActiveRecord::RecordNotFound")
    end
  end

  describe "schema surface" do
    it "has no required parameters" do
      expect(described_class.tool_name).to eq("list_memories")
      schema = described_class.input_schema_value.to_h
      expect(schema.fetch(:required, [])).to be_empty
    end
  end
end
