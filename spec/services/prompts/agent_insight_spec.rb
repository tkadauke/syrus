require "rails_helper"

RSpec.describe Prompts::AgentInsight do
  let(:repository) { Factories.repository }

  describe "#to_s" do
    it "includes the repository slug in the header" do
      out = described_class.new(repository: repository).to_s
      expect(out).to include(repository.slug)
    end

    it "includes submit_insight instructions" do
      out = described_class.new(repository: repository).to_s
      expect(out).to include("submit_insight")
    end

    describe "analysis window" do
      context "when analysis_window_start is provided" do
        let(:window_start) { Time.utc(2026, 7, 15, 10, 30, 0) }

        it "includes an Analysis Window section" do
          out = described_class.new(repository: repository, analysis_window_start: window_start).to_s
          expect(out).to include("## Analysis Window")
        end

        it "includes the ISO 8601 timestamp" do
          out = described_class.new(repository: repository, analysis_window_start: window_start).to_s
          expect(out).to include("2026-07-15T10:30:00Z")
        end

        it "instructs the agent not to re-examine earlier transcripts" do
          out = described_class.new(repository: repository, analysis_window_start: window_start).to_s
          expect(out).to include("Do not re-examine transcripts from earlier runs")
        end
      end

      context "when analysis_window_start is nil" do
        it "omits the Analysis Window section" do
          out = described_class.new(repository: repository).to_s
          expect(out).not_to include("Analysis Window")
          expect(out).not_to include("Do not re-examine transcripts from earlier runs")
        end
      end
    end

    describe "known insights" do
      context "when known_insights are provided" do
        let(:known_insights) do
          [
            instance_double(InsightSuggestion, title: "Agent repeatedly fails at rebase step", state: "accepted"),
            instance_double(InsightSuggestion, title: "Missing memory about test runner config", state: "dismissed")
          ]
        end

        it "includes a Known Insights section" do
          out = described_class.new(repository: repository, known_insights: known_insights).to_s
          expect(out).to include("## Known Insights")
        end

        it "lists each insight title with its state" do
          out = described_class.new(repository: repository, known_insights: known_insights).to_s
          expect(out).to include("Agent repeatedly fails at rebase step (accepted)")
          expect(out).to include("Missing memory about test runner config (dismissed)")
        end

        it "instructs the agent not to refile known insights" do
          out = described_class.new(repository: repository, known_insights: known_insights).to_s
          expect(out).to include("Do not refile")
        end

        it "lists insights in the order they are provided" do
          out = described_class.new(repository: repository, known_insights: known_insights).to_s
          accepted_pos  = out.index("Agent repeatedly fails at rebase step")
          dismissed_pos = out.index("Missing memory about test runner config")
          expect(accepted_pos).to be < dismissed_pos
        end
      end

      context "when known_insights is empty" do
        it "omits the Known Insights section" do
          out = described_class.new(repository: repository, known_insights: []).to_s
          expect(out).not_to include("Known Insights")
        end
      end
    end

    describe "memory dedup guidance" do
      it "instructs the agent to call list_memories before writing a new memory" do
        out = described_class.new(repository: repository).to_s
        expect(out).to include("list_memories")
        expect(out).to include("check whether a similar memory already exists")
      end
    end

    describe "recent jobs" do
      context "when recent_jobs are provided" do
        let(:job) { Factories.job_record(repository: repository, state: "closed") }

        it "includes a Recent Jobs section with the job identifier" do
          out = described_class.new(repository: repository, recent_jobs: [job]).to_s
          expect(out).to include("## Recent Jobs (last 14 days)")
          expect(out).to include("JOB-#{job.id}")
        end
      end

      context "when recent_jobs is empty" do
        it "omits the Recent Jobs section" do
          out = described_class.new(repository: repository, recent_jobs: []).to_s
          expect(out).not_to include("Recent Jobs")
        end
      end
    end
  end
end
