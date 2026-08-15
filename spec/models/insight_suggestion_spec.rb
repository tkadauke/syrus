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

    describe "#retire!" do
      it "transitions from pending to retired, stamps retired_at/reason, and records an audit event" do
        suggestion = create_suggestion

        expect {
          result = suggestion.retire!(reason: "Duplicate of a later finding.", actor: user)
          expect(result).to be true
        }.to change(InsightSuggestionAuditEvent, :count).by(1)

        suggestion.reload
        expect(suggestion.state).to eq("retired")
        expect(suggestion.retired_at).to be_present
        expect(suggestion.retired_reason).to eq("Duplicate of a later finding.")

        event = InsightSuggestionAuditEvent.last
        expect(event.insight_suggestion).to eq(suggestion)
        expect(event.event_type).to eq("retired")
        expect(event.actor_kind).to eq("user")
        expect(event.actor_user).to eq(user)
        expect(event.previous_values).to include("state" => "pending")
        expect(event.new_values).to include("state" => "retired")
      end

      it "retires a dismissed insight" do
        suggestion = create_suggestion(state: "dismissed", dismissed_at: 1.hour.ago)

        expect(suggestion.retire!(reason: "Stale.", actor: nil)).to be true
        expect(suggestion.reload.state).to eq("retired")
      end

      it "records superseded_by_insight and superseded_by_job when given" do
        suggestion = create_suggestion
        superseding = create_suggestion(title: "Newer finding")
        superseding_job = Factories.job(user: user, repository: repository)

        suggestion.retire!(
          reason: "Folded into a newer insight.",
          actor: nil,
          superseded_by_insight: superseding,
          superseded_by_job: superseding_job
        )

        suggestion.reload
        expect(suggestion.superseded_by_insight).to eq(superseding)
        expect(suggestion.superseded_by_job).to eq(superseding_job)
      end

      it "returns false and does not retire when already retired" do
        suggestion = create_suggestion
        suggestion.retire!(reason: "First retirement.", actor: nil)

        expect {
          expect(suggestion.retire!(reason: "Second attempt.", actor: nil)).to be false
        }.not_to change(InsightSuggestionAuditEvent, :count)
      end

      it "returns false for an accepted insight by default" do
        suggestion = create_suggestion
        suggestion.accept!

        expect(suggestion.retire!(reason: "Stale now.", actor: nil)).to be false
        expect(suggestion.reload.state).to eq("accepted")
      end

      it "retires an accepted insight when retire_accepted is true" do
        suggestion = create_suggestion
        suggestion.accept!

        result = suggestion.retire!(reason: "Confirmed obsolete.", actor: nil, retire_accepted: true)

        expect(result).to be true
        expect(suggestion.reload.state).to eq("retired")
      end

      it "requires a retired_reason to be valid once retired" do
        suggestion = create_suggestion
        suggestion.update_columns(state: "retired")

        expect(suggestion.reload).not_to be_valid
        expect(suggestion.errors[:retired_reason]).to be_present
      end

      it "rejects a superseded_by_insight that references itself" do
        suggestion = create_suggestion
        suggestion.update_columns(state: "retired", retired_reason: "x")
        suggestion.superseded_by_insight_id = suggestion.id

        expect(suggestion).not_to be_valid
        expect(suggestion.errors[:superseded_by_insight]).to be_present
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

    it "#retired? returns true after retire!" do
      suggestion = create_suggestion
      suggestion.retire!(reason: "Stale.", actor: nil)

      expect(suggestion.retired?).to be true
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

    it ".retired only returns retired suggestions" do
      s1 = create_suggestion
      s2 = create_suggestion
      s2.retire!(reason: "Stale.", actor: nil)

      expect(InsightSuggestion.retired).to include(s2)
      expect(InsightSuggestion.retired).not_to include(s1)
    end

    it ".active excludes retired suggestions" do
      s1 = create_suggestion
      s2 = create_suggestion
      s2.retire!(reason: "Stale.", actor: nil)

      expect(InsightSuggestion.active).to include(s1)
      expect(InsightSuggestion.active).not_to include(s2)
    end
  end
end
