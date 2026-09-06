require "rails_helper"

RSpec.describe Filters::Chips::Jobs::EligibleApprover do
  let(:user) { Factories.user }
  let(:other_user) { Factories.user }
  let(:third_user) { Factories.user }

  def run(op:, value: nil, scope:, current_user: user)
    Filters::Compiler.call(
      Filters::Ast.parse("field" => "eligible_approver", "op" => op, "value" => value),
      scope: scope,
      user: current_user,
      subject: :job
    )
  end

  describe "review_policy: self" do
    let(:repo) { Factories.repository(user: user, owner: "acme", name: "self-widgets", review_policy: "self") }
    let!(:owned_by_me) { Factories.job(user: other_user, repository: repo, owner_user: user) }
    let!(:owned_by_other) { Factories.job(user: user, repository: repo, owner_user: other_user) }

    it "only includes jobs the user effectively owns" do
      result = run(op: "is", value: "me", scope: Job.where(repository: repo))
      expect(result).to contain_exactly(owned_by_me)
    end

    it "excludes jobs owned by anyone else, even the raw creator" do
      result = run(op: "is", value: "me", scope: Job.where(repository: repo))
      expect(result).not_to include(owned_by_other)
    end

    it "is_not returns everything the user does not effectively own" do
      result = run(op: "is_not", value: "me", scope: Job.where(repository: repo))
      expect(result).to contain_exactly(owned_by_other)
    end
  end

  describe "review_policy: two_person" do
    let(:repo) { Factories.repository(user: user, owner: "acme", name: "two-person-widgets", review_policy: "two_person") }
    let!(:owned_by_me) { Factories.job(user: other_user, repository: repo, owner_user: user) }
    let!(:created_by_me_owned_by_other) { Factories.job(user: user, repository: repo, owner_user: other_user) }
    let!(:created_and_owned_by_other) { Factories.job(user: other_user, repository: repo, owner_user: other_user) }

    it "includes jobs the user effectively owns" do
      result = run(op: "is", value: "me", scope: Job.where(repository: repo))
      expect(result).to include(owned_by_me)
    end

    it "includes jobs the user did not create, even without owning them (any non-owner approval counts)" do
      result = run(op: "is", value: "me", scope: Job.where(repository: repo))
      expect(result).to include(created_and_owned_by_other)
    end

    it "excludes a job the user themself raw-created but does not own" do
      result = run(op: "is", value: "me", scope: Job.where(repository: repo))
      expect(result).not_to include(created_by_me_owned_by_other)
    end
  end

  describe "review_policy: final_say" do
    let(:repo) { Factories.repository(user: user, owner: "acme", name: "final-say-widgets", review_policy: "final_say") }
    let!(:owned_by_me) { Factories.job(user: other_user, repository: repo, owner_user: user) }
    let!(:owned_by_other_no_final_say) { Factories.job(user: user, repository: repo, owner_user: other_user) }
    let!(:owned_by_third_party) { Factories.job(user: third_user, repository: repo, owner_user: third_user) }

    before do
      RepositoryFinalApprover.create!(repository: repo, user: user)
    end

    it "includes jobs the user effectively owns" do
      result = run(op: "is", value: "me", scope: Job.where(repository: repo))
      expect(result).to include(owned_by_me)
    end

    it "includes jobs owned by others when the user is a registered final approver" do
      result = run(op: "is", value: "me", scope: Job.where(repository: repo))
      expect(result).to include(owned_by_other_no_final_say, owned_by_third_party)
    end

    it "excludes jobs for a user who is neither the owner nor a final approver" do
      result = run(op: "is", value: third_user.id.to_s, scope: Job.where(repository: repo))
      expect(result).to contain_exactly(owned_by_third_party)
    end
  end

  describe "is a specific user id" do
    let(:repo) { Factories.repository(user: user, owner: "acme", name: "specific-widgets", review_policy: "self") }
    let!(:owned_by_other) { Factories.job(user: user, repository: repo, owner_user: other_user) }

    it "resolves eligibility for the given user id, not the current user" do
      result = run(op: "is", value: other_user.id.to_s, scope: Job.where(repository: repo))
      expect(result).to contain_exactly(owned_by_other)
    end

    it "returns no results for an unknown user id" do
      result = run(op: "is", value: "999999", scope: Job.where(repository: repo))
      expect(result).to be_empty
    end
  end

  describe "with no current user" do
    let(:repo) { Factories.repository(user: user, owner: "acme", name: "no-user-widgets", review_policy: "self") }
    let!(:job) { Factories.job(user: user, repository: repo, owner_user: user) }

    it "returns no results for is: me" do
      result = run(op: "is", value: "me", scope: Job.where(repository: repo), current_user: nil)
      expect(result).to be_empty
    end
  end

  describe "chip metadata" do
    it "registers as eligible_approver in the job subject" do
      other_user # ensure created before querying schema_values' user list
      schema = Filters::Schema.for(subject: :job, user: user)
      chip = schema.find { |c| c["field"] == "eligible_approver" }

      expect(chip).not_to be_nil
      expect(chip["label"]).to eq("Eligible approver")
      expect(chip["bucket"]).to eq("enum")
      expect(chip["operators"]).to contain_exactly("is", "is_not")
      values = chip["values"].map { |v| v["value"] }
      expect(values).to include("me", user.id.to_s, other_user.id.to_s)
    end
  end
end
