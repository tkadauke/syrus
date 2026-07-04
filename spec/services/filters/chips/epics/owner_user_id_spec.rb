require "rails_helper"

RSpec.describe Filters::Chips::Epics::OwnerUserId do
  let(:user) { Factories.user }
  let(:other_user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def run(op:, value: nil, current_user: user)
    Filters::Compiler.call(
      Filters::Ast.parse("field" => "owner_user_id", "op" => op, "value" => value),
      scope: Epic.where(repository: repo),
      user: current_user,
      subject: :epic
    )
  end

  let!(:mine_by_user_id) { Factories.epic(user: user, repository: repo, owner_user: user) }
  let!(:mine_by_owner_id) do
    Factories.epic(user: user, repository: repo).tap { |e| e.update_columns(owner_id: user.id, owner_user_id: nil) }
  end
  let!(:theirs) { Factories.epic(user: user, repository: repo, owner_user: other_user) }
  let!(:unclaimed) do
    Factories.epic(user: user, repository: repo).tap { |e| e.update_columns(owner_id: nil, owner_user_id: nil) }
  end

  describe "is me" do
    it "returns epics owned by the current user via owner_user_id" do
      expect(run(op: "is", value: "me")).to include(mine_by_user_id)
    end

    it "returns epics owned by the current user via owner_id fallback" do
      expect(run(op: "is", value: "me")).to include(mine_by_owner_id)
    end

    it "excludes epics owned by other users" do
      expect(run(op: "is", value: "me")).not_to include(theirs)
    end

    it "excludes unclaimed epics" do
      expect(run(op: "is", value: "me")).not_to include(unclaimed)
    end

    it "returns no results when no user is provided" do
      expect(run(op: "is", value: "me", current_user: nil)).to be_empty
    end
  end

  describe "is unclaimed" do
    it "returns epics with no owner set" do
      expect(run(op: "is", value: "unclaimed")).to contain_exactly(unclaimed)
    end

    it "excludes epics owned by anyone" do
      expect(run(op: "is", value: "unclaimed")).not_to include(mine_by_user_id, mine_by_owner_id, theirs)
    end
  end

  describe "is_not me" do
    it "excludes epics owned by the current user" do
      result = run(op: "is_not", value: "me")
      expect(result).not_to include(mine_by_user_id, mine_by_owner_id)
      expect(result).to include(theirs, unclaimed)
    end
  end

  describe "is_not unclaimed" do
    it "excludes unclaimed epics" do
      result = run(op: "is_not", value: "unclaimed")
      expect(result).not_to include(unclaimed)
      expect(result).to include(mine_by_user_id, mine_by_owner_id, theirs)
    end
  end

  describe "is_set" do
    it "returns epics that have any owner" do
      result = run(op: "is_set")
      expect(result).to include(mine_by_user_id, mine_by_owner_id, theirs)
      expect(result).not_to include(unclaimed)
    end
  end

  describe "is_unset" do
    it "returns epics with no owner" do
      expect(run(op: "is_unset")).to contain_exactly(unclaimed)
    end
  end

  describe "chip metadata" do
    it "registers as owner_user_id in the epic subject" do
      schema = Filters::Schema.for(subject: :epic, user: user)
      chip = schema.find { |c| c["field"] == "owner_user_id" }

      expect(chip).not_to be_nil
      expect(chip["label"]).to eq("Owner")
      expect(chip["bucket"]).to eq("enum")
      expect(chip["operators"]).to include("is", "is_not", "is_set", "is_unset")
      values = chip["values"].map { |v| v["value"] }
      expect(values).to include("me", "unclaimed")
    end
  end
end
