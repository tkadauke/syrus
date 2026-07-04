require "rails_helper"

RSpec.describe Filters::Chips::Jobs::OwnerUserId do
  let(:user) { Factories.user }
  let(:other_user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def run(op:, value: nil, current_user: user)
    Filters::Compiler.call(
      Filters::Ast.parse("field" => "owner_user_id", "op" => op, "value" => value),
      scope: Job.where(repository: repo),
      user: current_user,
      subject: :job
    )
  end

  let!(:mine) { Factories.job(user: user, repository: repo, owner_user: user) }
  let!(:theirs) { Factories.job(user: user, repository: repo, owner_user: other_user) }
  let!(:unclaimed) do
    Factories.job(user: user, repository: repo).tap { |j| j.update_columns(owner_user_id: nil) }
  end

  describe "is me" do
    it "returns jobs owned by the current user" do
      expect(run(op: "is", value: "me")).to include(mine)
    end

    it "excludes jobs owned by other users" do
      expect(run(op: "is", value: "me")).not_to include(theirs)
    end

    it "excludes unclaimed jobs" do
      expect(run(op: "is", value: "me")).not_to include(unclaimed)
    end

    it "returns no results when no user is provided" do
      expect(run(op: "is", value: "me", current_user: nil)).to be_empty
    end
  end

  describe "is unclaimed" do
    it "returns jobs with no owner set" do
      expect(run(op: "is", value: "unclaimed")).to contain_exactly(unclaimed)
    end

    it "excludes jobs owned by anyone" do
      expect(run(op: "is", value: "unclaimed")).not_to include(mine, theirs)
    end
  end

  describe "is specific user" do
    it "returns jobs owned by the specified user id" do
      expect(run(op: "is", value: other_user.id.to_s)).to contain_exactly(theirs)
    end

    it "returns no results for an unknown user id" do
      expect(run(op: "is", value: "999999")).to be_empty
    end
  end

  describe "is_not me" do
    it "excludes jobs owned by the current user" do
      result = run(op: "is_not", value: "me")
      expect(result).not_to include(mine)
      expect(result).to include(theirs, unclaimed)
    end
  end

  describe "is_not unclaimed" do
    it "excludes unclaimed jobs" do
      result = run(op: "is_not", value: "unclaimed")
      expect(result).not_to include(unclaimed)
      expect(result).to include(mine, theirs)
    end
  end

  describe "is_not specific user" do
    it "excludes jobs owned by the specified user id, includes others and unclaimed" do
      result = run(op: "is_not", value: other_user.id.to_s)
      expect(result).not_to include(theirs)
      expect(result).to include(mine, unclaimed)
    end
  end

  describe "is_set" do
    it "returns jobs that have any owner" do
      result = run(op: "is_set")
      expect(result).to include(mine, theirs)
      expect(result).not_to include(unclaimed)
    end
  end

  describe "is_unset" do
    it "returns jobs with no owner" do
      expect(run(op: "is_unset")).to contain_exactly(unclaimed)
    end
  end

  describe "chip metadata" do
    it "registers as owner_user_id in the job subject" do
      schema = Filters::Schema.for(subject: :job, user: user)
      chip = schema.find { |c| c["field"] == "owner_user_id" }

      expect(chip).not_to be_nil
      expect(chip["label"]).to eq("Owner")
      expect(chip["bucket"]).to eq("enum")
      expect(chip["operators"]).to include("is", "is_not", "is_set", "is_unset")
      values = chip["values"].map { |v| v["value"] }
      expect(values).to include("me", "unclaimed", user.id.to_s, other_user.id.to_s)
    end

    it "does not expose typeahead" do
      schema = Filters::Schema.for(subject: :job, user: user)
      chip = schema.find { |c| c["field"] == "owner_user_id" }
      expect(chip["typeahead"]).to be_nil
    end
  end
end
