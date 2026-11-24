module Achievements
  # One adapter per domain event the evaluators understand. An adapter turns an
  # event payload into the three things evaluation needs -- did the thing
  # complete, who may be credited, and what is it about -- so evaluators stay
  # event-agnostic and adding an event is adding a class.
  module EventAdapters
    class Base
      # Subclasses decide which work is creditable to a person: only work an
      # operator started themselves. Scheduled fires, ingested issues, coworker
      # or insight work and infrastructure belong to the installation, not to
      # whichever account happens to own the record.
      def self.credits_user?(user_id) = user_id.present? && ::User.exists?(id: user_id)

      def initialize(event) = @event = event

      attr_reader :event

      def completed? = raise(NotImplementedError)
      def attributed_user_id = raise(NotImplementedError)
      def subject = raise(NotImplementedError)
      def evidence = raise(NotImplementedError)
    end

    class JobClosed < Base
      LANDED_REASONS = %w[pr_merged].freeze
      CREDITED_KINDS = %w[direct].freeze
      CREDITED_ORIGIN = "core".freeze

      def completed? = event[:job_id].present? && LANDED_REASONS.include?(event[:closure_reason].to_s)

      # Only an operator's own direct prompt, created by core rather than a
      # plugin or scheduler, credits its creator. Closing, merging, or
      # reviewing someone else's Job never does.
      def attributed_user_id
        return nil unless CREDITED_KINDS.include?(event[:kind].to_s) && event[:origin].to_s == CREDITED_ORIGIN

        self.class.credits_user?(event[:user_id]) ? event[:user_id] : nil
      end

      def subject = Subject.new(kind: :job, id: event[:job_id])

      def evidence
        { "event" => event.name, "closure_reason" => event[:closure_reason].to_s, "kind" => event[:kind].to_s }
      end
    end

    class EpicUpserted < Base
      DONE_STATE = "done".freeze
      CREDITED_ORIGIN = "operator".freeze

      def completed? = event[:epic_id].present? && event[:state].to_s == DONE_STATE

      def attributed_user_id
        return nil unless event[:origin].to_s == CREDITED_ORIGIN

        self.class.credits_user?(event[:user_id]) ? event[:user_id] : nil
      end

      def subject = Subject.new(kind: :epic, id: event[:epic_id])

      def evidence = { "event" => event.name, "state" => event[:state].to_s }
    end

    REGISTRY = { "job.closed" => JobClosed, "epic.upserted" => EpicUpserted }.freeze

    def self.for(event) = REGISTRY[event.name]&.new(event)
    def self.event_names = REGISTRY.keys
  end
end
