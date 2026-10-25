module ProviderRouting
  class PanelConsensus
    Result = Data.define(:verdict, :breakdown) do
      def to_h = { verdict: verdict, vote_breakdown: breakdown }
    end

    def self.call(member_verdicts:, consensus:, min_members:)
      new(member_verdicts: member_verdicts, consensus: consensus, min_members: min_members).call
    end

    def initialize(member_verdicts:, consensus:, min_members:)
      @verdicts = Array(member_verdicts).map { |entry| entry.respond_to?(:to_h) ? entry.to_h.with_indifferent_access[:verdict].to_s : entry.to_s }
      @consensus = consensus
      @min_members = min_members.to_i
    end

    def call
      counted = verdicts.reject { |verdict| verdict == "skipped" }
      breakdown = {
        "approved" => counted.count("approved"),
        "needs_work" => counted.count("needs_work"),
        "skipped" => verdicts.count("skipped"),
        "counted" => counted.size,
        "total" => verdicts.size,
        "required_approvals" => required_approvals(counted.size),
        "min_members" => min_members
      }
      verdict = if counted.size < min_members
        "skipped"
      elsif breakdown["approved"] >= breakdown["required_approvals"]
        "approved"
      else
        "needs_work"
      end
      Result.new(verdict: verdict, breakdown: breakdown)
    end

    private

    attr_reader :verdicts, :consensus, :min_members

    def required_approvals(counted_members)
      return counted_members if consensus.to_s == "unanimous"
      return (counted_members / 2) + 1 if consensus.to_s == "majority"

      consensus.to_h.with_indifferent_access.fetch(:at_least).to_i
    end
  end
end
