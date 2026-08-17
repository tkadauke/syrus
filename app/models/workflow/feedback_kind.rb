class Workflow
  # Polymorphic replacement for hand-rolled
  # `case Workflow::TriggerKind.feedback_kind_for(workflow.trigger_kind)`
  # switches that used to be duplicated across job_detail_payload,
  # refresh_job_metadata, adversarial_review, and visual_review. Callers ask
  # `Workflow::FeedbackKind.for(workflow)` and get back one object (or nil for
  # trigger kinds that carry no feedback, e.g. initial/ci_failure/rebase)
  # instead of re-deriving the discriminator and branching on it themselves.
  module FeedbackKind
    def self.for(workflow)
      kind = TriggerKind.feedback_kind_for(workflow.trigger_kind)
      return nil unless kind

      REGISTRY.fetch(kind).new(workflow)
    end

    class Base
      attr_reader :workflow

      def initialize(workflow)
        @workflow = workflow
      end

      # Machine-readable discriminator for UI payloads.
      def kind_name = raise NotImplementedError
      # Whether this workflow actually carries feedback content worth showing.
      def present? = raise NotImplementedError
      # Unadorned text, used to feed prompts (no author/inline attribution).
      def plain_text = raise NotImplementedError
      # Attributed text for the review agents' prompt context; nil when empty.
      def review_text = raise NotImplementedError
      # Attributed text for the feedback history UI list.
      def history_body = raise NotImplementedError
      # Extra provenance metadata; only chat feedback carries this.
      def feedback_source = nil
    end

    class ChatFeedback < Base
      def kind_name = "chat_feedback"
      def present? = chat_body.present?
      def plain_text = chat_body.to_s
      def review_text = chat_body.to_s.presence
      def history_body = chat_body
      def feedback_source = workflow.artifact("feedback_source")

      private

      def chat_body
        workflow.artifact("chat_feedback")
      end
    end

    class PrComment < Base
      def kind_name = "pr_comment"
      def present? = comments.any?
      def plain_text = comments.map { |c| c["body"].to_s }.reject(&:blank?).join("\n\n")

      def review_text
        return nil if comments.empty?

        comments.map { |c| render_review_comment(c) }.join("\n\n")
      end

      def history_body
        comments.map { |c| render_history_comment(c) }.join("\n\n")
      end

      private

      def comments
        Array(workflow.artifact("pr_comments"))
      end

      def render_review_comment(c)
        author = c["author"].presence || "reviewer"
        body   = c["body"].to_s
        if c["path"].present?
          "[Inline on #{c["path"]}:#{c["line"]}] @#{author}: #{body}"
        else
          "@#{author}: #{body}"
        end
      end

      def render_history_comment(c)
        author = c["author"].present? ? "@#{c["author"]}: " : ""
        "#{author}#{c["body"]}"
      end
    end

    REGISTRY = {
      chat_feedback: ChatFeedback,
      pr_comment: PrComment
    }.freeze
  end
end
