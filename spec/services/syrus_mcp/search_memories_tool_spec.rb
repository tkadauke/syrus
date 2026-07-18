require "rails_helper"

RSpec.describe SyrusMcp::SearchMemoriesTool do
  let(:run) { Factories.job.initial_run }
  let(:user) { run.job.user }
  let(:repository) { run.job.repository }

  def create_memory(owner: user, repo: repository, published: false, **attrs)
    ChatMemory.create!({
      user: owner,
      kind: "feedback",
      scope: "repository",
      scope_id: repo.id,
      content: "Default content.",
      published: published
    }.merge(attrs))
  end

  def call(query:, context: { run_id: run.id }, **kwargs)
    described_class.call(query: query, **kwargs, server_context: context)
  end

  describe ".call" do
    it "returns memories matching the query within the job's repository" do
      matching = create_memory(content: "Use short functions for readability.")
      _unrelated = create_memory(content: "Unrelated content about deploy pipelines.")

      response = call(query: "short functions")

      expect(response).not_to be_error
      payload = JSON.parse(response.content.first[:text])
      ids = payload["memories"].map { |m| m["id"] }
      expect(ids).to include(matching.id)
    end

    it "includes published memories from other users in the same repository" do
      other_user = Factories.user
      published_memory = create_memory(owner: other_user, content: "Shared team convention.", published: true)

      response = call(query: "Shared team")

      payload = JSON.parse(response.content.first[:text])
      ids = payload["memories"].map { |m| m["id"] }
      expect(ids).to include(published_memory.id)
    end

    it "excludes unpublished memories from other users" do
      other_user = Factories.user
      private_memory = create_memory(owner: other_user, content: "Private convention.", published: false)

      response = call(query: "Private convention")

      payload = JSON.parse(response.content.first[:text])
      ids = payload["memories"].map { |m| m["id"] }
      expect(ids).not_to include(private_memory.id)
    end

    it "excludes memories from other repositories" do
      other_repo = Factories.repository(user: user)
      other_repo_memory = create_memory(repo: other_repo, content: "Cross-repo memory content.")

      response = call(query: "Cross-repo memory")

      payload = JSON.parse(response.content.first[:text])
      ids = payload["memories"].map { |m| m["id"] }
      expect(ids).not_to include(other_repo_memory.id)
    end

    it "excludes soft-deleted memories" do
      memory = create_memory(content: "Deleted convention content.")
      memory.update!(deleted_at: Time.current)

      response = call(query: "Deleted convention")

      payload = JSON.parse(response.content.first[:text])
      ids = payload["memories"].map { |m| m["id"] }
      expect(ids).not_to include(memory.id)
    end

    it "filters by kind" do
      feedback = create_memory(content: "Always test your code.", kind: "feedback")
      fact = create_memory(content: "Always use snake_case.", kind: "project_fact")

      response = call(query: "Always", kind: "project_fact")

      payload = JSON.parse(response.content.first[:text])
      ids = payload["memories"].map { |m| m["id"] }
      expect(ids).to include(fact.id)
      expect(ids).not_to include(feedback.id)
    end

    it "returns an error for an empty query" do
      response = call(query: "  ")

      expect(response).to be_error
      expect(response.content.first[:text]).to include("query is required")
    end

    it "returns an error for an invalid kind" do
      response = call(query: "something", kind: "not_a_kind")

      expect(response).to be_error
      expect(response.content.first[:text]).to include("kind must be one of")
    end

    it "returns an error for an invalid run context" do
      response = call(query: "anything", context: { run_id: 0 })

      expect(response).to be_error
      expect(response.content.first[:text]).to include("ActiveRecord::RecordNotFound")
    end
  end

  describe "schema surface" do
    it "requires a query parameter" do
      expect(described_class.tool_name).to eq("search_memories")
      schema = described_class.input_schema_value.to_h
      expect(schema[:required]).to eq(%w[query])
      expect(schema.dig(:properties, :query, :type)).to eq("string")
    end
  end
end
