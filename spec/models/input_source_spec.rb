require "rails_helper"

RSpec.describe InputSource do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  describe "unique constraint on [repository_id, type]" do
    it "creates one InputSources::Github per repository automatically" do
      expect(repository.github_input_source).to be_present
      expect(repository.github_input_source.type).to eq("InputSources::Github")
    end

    it "rejects a second input source of the same type for the same repository" do
      duplicate = InputSources::Github.new(
        repository: repository,
        user: user,
        config: { "trigger_label" => "other" }
      )
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:repository_id]).to be_present
    end
  end

  describe "#active?" do
    it "returns true when polling_enabled and repository is present" do
      source = repository.github_input_source
      expect(source.active?).to be true
    end

    it "returns false when polling is disabled" do
      source = repository.github_input_source
      source.update!(polling_enabled: false)
      expect(source.active?).to be false
    end
  end

  describe "config default" do
    it "seeds an empty hash when config is not provided" do
      source = InputSources::Github.new(repository: repository, user: user)
      expect(source.config).to eq({})
    end
  end

  describe "STI loading" do
    it "resolves a persisted GitHub row using the class name after the model moved into a plugin" do
      source_id = repository.github_input_source.id

      expect(InputSource.find(source_id)).to be_a(InputSources::Github)
    end
  end

  describe "data migration backfill" do
    it "creates an InputSources::Github record automatically when a repository is created" do
      repo = Repository.create!(user: user, owner: "acme", name: "test-#{SecureRandom.hex(4)}")

      expect(repo.github_input_source).to be_present
      expect(repo.github_input_source.config["trigger_label"]).to eq("syrus")
      expect(repo.github_input_source.polling_enabled).to be true
      expect(repo.github_input_source.user_id).to eq(user.id)
    end

    it "copies the repository trigger_label into the input source config" do
      repo = Repository.create!(
        user: user,
        owner: "acme",
        name: "test-#{SecureRandom.hex(4)}",
        trigger_label: "automate-me"
      )

      expect(repo.github_input_source.config["trigger_label"]).to eq("automate-me")
    end

    it "reads trigger_label through the input source config" do
      repo = Repository.create!(user: user, owner: "acme", name: "test-#{SecureRandom.hex(4)}", trigger_label: "deploy")
      repo.github_input_source.update_columns(config: { "trigger_label" => "ship-it" })
      repo.reload

      expect(repo.trigger_label).to eq("ship-it")
    end

    it "reads polling_enabled through the input source" do
      repo = Repository.create!(user: user, owner: "acme", name: "test-#{SecureRandom.hex(4)}")
      repo.github_input_source.update_columns(polling_enabled: false)
      repo.reload

      expect(repo.polling_enabled?).to be false
    end

    it "syncs polling_enabled change to the input source" do
      repo = Repository.create!(user: user, owner: "acme", name: "test-#{SecureRandom.hex(4)}")
      repo.update!(polling_enabled: false)

      expect(repo.github_input_source.reload.polling_enabled).to be false
    end

    it "syncs trigger_label change to the input source config" do
      repo = Repository.create!(user: user, owner: "acme", name: "test-#{SecureRandom.hex(4)}")
      repo.update!(trigger_label: "new-label")

      expect(repo.github_input_source.reload.config["trigger_label"]).to eq("new-label")
    end
  end
end
