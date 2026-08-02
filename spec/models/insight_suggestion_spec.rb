require "rails_helper"

RSpec.describe InsightSuggestion do
  let(:user)        { Factories.user }
  let(:repository)  { Factories.repository(user: user) }
  let(:job)         { Factories.job(user: user, repository: repository) }

  def build_suggestion(**attrs)
    InsightSuggestion.new({
      job:        job,
      repository: repository,
      title:      "Repeated prepare failures",
      category:   "repeated_failure",
      severity:   "medium",
      confidence: 0.8
    }.merge(attrs))
  end

  def create_suggestion(**attrs)
    build_suggestion(**attrs).tap(&:save!)
  end

  describe "validations" do
    it "is valid with all required fields" do
      expect(build_suggestion).to be_valid
    end

    it "requires a title" do
      expect(build_suggestion(title: "")).not_to be_valid
    end

    it "requires a category" do
      expect(build_suggestion(category: "")).not_to be_valid
    end

    it "requires a valid severity" do
      expect(build_suggestion(severity: "critical")).not_to be_valid
      expect(build_suggestion(severity: "low")).to be_valid
      expect(build_suggestion(severity: "medium")).to be_valid
      expect(build_suggestion(severity: "high")).to be_valid
    end

    it "requires confidence between 0.0 and 1.0" do
      expect(build_suggestion(confidence: -0.1)).not_to be_valid
      expect(build_suggestion(confidence: 1.1)).not_to be_valid
      expect(build_suggestion(confidence: 0.0)).to be_valid
      expect(build_suggestion(confidence: 1.0)).to be_valid
    end

    it "defaults state to pending" do
      suggestion = create_suggestion
      expect(suggestion.state).to eq("pending")
    end

    it "accepts remove_memory proposals with a target memory and explanation" do
      memory = ChatMemory.create!(
        user: user,
        kind: "project_fact",
        scope: "repository",
        scope_id: repository.id,
        content: "Old bug still exists."
      )

      suggestion = build_suggestion(
        proposal_type: "remove_memory",
        target_memory: memory,
        stale_memory_text: memory.content,
        stale_memory_evidence: "The referenced bug was fixed by JOB-123."
      )

      expect(suggestion).to be_valid
    end

    it "requires a target memory for remove_memory proposals" do
      suggestion = build_suggestion(proposal_type: "remove_memory", stale_memory_evidence: "Fixed.")

      expect(suggestion).not_to be_valid
      expect(suggestion.errors[:target_memory]).to include("must be present for remove_memory proposals")
    end

    it "infers legacy create_job suggestions from suggested_prompt" do
      expect(build_suggestion(proposal_type: "informational", suggested_prompt: "Fix it").effective_proposal_type).to eq("create_job")
    end

    it "infers legacy save_memory suggestions from memory_suggestion" do
      suggestion = build_suggestion(proposal_type: "informational", memory_suggestion: "Remember this.")

      expect(suggestion.effective_proposal_type).to eq("save_memory")
    end
  end

  describe "state transitions" do
    describe "#accept!" do
      it "transitions from pending to accepted and stamps accepted_at" do
        suggestion = create_suggestion

        result = suggestion.accept!

        expect(result).to be true
        expect(suggestion.reload.state).to eq("accepted")
        expect(suggestion.accepted_at).to be_present
      end

      it "records the created_job when provided" do
        suggestion = create_suggestion
        created = Factories.job(user: user, repository: repository)

        suggestion.accept!(created_job: created)

        expect(suggestion.reload.created_job).to eq(created)
      end

      it "returns false and does not transition when already accepted" do
        suggestion = create_suggestion
        suggestion.update_columns(state: "accepted")

        result = suggestion.accept!

        expect(result).to be false
        expect(suggestion.reload.state).to eq("accepted")
      end

      it "returns false when already dismissed" do
        suggestion = create_suggestion
        suggestion.update_columns(state: "dismissed")

        expect(suggestion.accept!).to be false
      end
    end

    describe "#dismiss!" do
      it "transitions from pending to dismissed and stamps dismissed_at" do
        suggestion = create_suggestion

        result = suggestion.dismiss!

        expect(result).to be true
        expect(suggestion.reload.state).to eq("dismissed")
        expect(suggestion.dismissed_at).to be_present
      end

      it "returns false and does not transition when already dismissed" do
        suggestion = create_suggestion
        suggestion.update_columns(state: "dismissed")

        expect(suggestion.dismiss!).to be false
      end

      it "returns false when already accepted" do
        suggestion = create_suggestion
        suggestion.update_columns(state: "accepted")

        expect(suggestion.dismiss!).to be false
      end
    end

    describe "#undismiss!" do
      it "transitions from dismissed back to pending and clears dismissed_at" do
        suggestion = create_suggestion
        suggestion.dismiss!

        result = suggestion.undismiss!

        expect(result).to be true
        expect(suggestion.reload.state).to eq("pending")
        expect(suggestion.reload.dismissed_at).to be_nil
      end

      it "returns false when suggestion is pending" do
        suggestion = create_suggestion

        expect(suggestion.undismiss!).to be false
        expect(suggestion.reload.state).to eq("pending")
      end

      it "returns false when suggestion is accepted" do
        suggestion = create_suggestion
        suggestion.update_columns(state: "accepted")

        expect(suggestion.undismiss!).to be false
      end
    end
  end

  describe "predicates" do
    it "#pending? returns true for pending state" do
      expect(create_suggestion.pending?).to be true
    end

    it "#accepted? returns true after accept!" do
      suggestion = create_suggestion
      suggestion.accept!

      expect(suggestion.accepted?).to be true
    end

    it "#dismissed? returns true after dismiss!" do
      suggestion = create_suggestion
      suggestion.dismiss!

      expect(suggestion.dismissed?).to be true
    end
  end

  describe "scopes" do
    it ".for_repository scopes to the given repository" do
      other_repo = Factories.repository(user: user)
      other_job  = Factories.job(user: user, repository: other_repo)
      create_suggestion
      InsightSuggestion.create!(
        job: other_job, repository: other_repo,
        title: "Other", category: "c", severity: "low", confidence: 0.5
      )

      expect(InsightSuggestion.for_repository(repository).count).to eq(1)
    end

    it ".pending only returns pending suggestions" do
      s1 = create_suggestion
      s2 = create_suggestion
      s2.accept!

      expect(InsightSuggestion.pending).to include(s1)
      expect(InsightSuggestion.pending).not_to include(s2)
    end
  end
end
