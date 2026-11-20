class Coworkers::JobGoalSummary
  MAX_LENGTH = 240
  GENERIC_TITLE = /\AScheduled coworker task(?::|\z)/i
  METADATA = /\A(?:metadata|repository|schedule|trigger|created|date|time|priority|job)\s*:/i

  def initialize(job)
    @job = job
  end

  def call
    source = descriptive_title? ? job.issue_title : job.issue_body
    sentence = first_substantive_line(source)
    sentence.presence&.truncate(MAX_LENGTH, separator: " ") || I18n.t("api.coworkers.no_goal_summary")
  end

  private

  attr_reader :job

  def descriptive_title?
    job.issue_title.present? && !job.issue_title.match?(GENERIC_TITLE)
  end

  def first_substantive_line(source)
    in_fence = false
    source.to_s.each_line.filter_map do |raw_line|
      line = raw_line.strip
      if line.start_with?("```")
        in_fence = !in_fence
        next
      end
      next if in_fence || line.blank? || line.start_with?("#") || line.match?(METADATA)

      line = line.sub(/\A(?:[-*+]\s+|\d+[.)]\s+)/, "").strip
      next if line.blank? || line.match?(METADATA)

      line.split(/(?<=[.!?])\s+/, 2).first
    end.first
  end
end
