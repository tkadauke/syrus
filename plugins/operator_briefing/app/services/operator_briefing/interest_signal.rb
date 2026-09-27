module OperatorBriefing
  class InterestSignal
    EXPLICIT_FEEDBACK_CONFIDENCE = 0.65
    DIVE_CONFIDENCE = 0.9

    def self.record_feedback!(feedback)
      new(
        user: feedback.user,
        briefing: feedback.briefing || feedback.briefing_item&.briefing,
        briefing_item: feedback.briefing_item,
        signal: "explicit_feedback",
        sentiment: feedback.sentiment,
        note: feedback.note,
        confidence: feedback.weight.presence || EXPLICIT_FEEDBACK_CONFIDENCE,
        source_id: feedback.id
      ).record!
    end

    def self.record_dive_completed!(user:, briefing:, briefing_item: nil, topic_title:, note: nil)
      new(
        user: user,
        briefing: briefing,
        briefing_item: briefing_item,
        signal: "completed_dive",
        topic_title: topic_title,
        note: note,
        confidence: DIVE_CONFIDENCE,
        source_id: briefing_item&.id || briefing.id
      ).record!
    end

    def initialize(user:, briefing:, signal:, confidence:, source_id:, briefing_item: nil, sentiment: nil, note: nil, topic_title: nil)
      @user = user
      @briefing = briefing
      @briefing_item = briefing_item
      @signal = signal
      @sentiment = sentiment
      @note = note.to_s.squish.presence
      @topic_title = topic_title.to_s.squish.presence
      @confidence = confidence
      @source_id = source_id
    end

    def record!
      AgentMemory::Entry.create!(
        user: user,
        kind: "user_pref",
        scope: "global",
        content: content,
        author: "user",
        source_type: "manual",
        source_id: source_id,
        confidence: confidence
      )
    end

    private

    attr_reader :user, :briefing, :briefing_item, :signal, :sentiment, :note, :topic_title, :confidence, :source_id

    def content
      parts = [ "Operator briefing preference signal: #{signal.humanize.downcase}." ]
      parts << "Repository: #{briefing.repository.slug}." if briefing&.repository
      parts << "Briefing item: #{briefing_item.narrative.squish.truncate(180)}." if briefing_item
      parts << "Topic: #{topic_title}." if topic_title
      parts << "Sentiment: #{sentiment}." if sentiment.present?
      parts << "Note: #{note}." if note.present?
      parts.join(" ").truncate(AgentMemory::Entry::CONTENT_MAX_LENGTH)
    end
  end
end
