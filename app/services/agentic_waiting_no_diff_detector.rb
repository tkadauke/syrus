class AgenticWaitingNoDiffDetector
  BACKGROUND_TOOL_NAMES = %w[Bash command_execution Monitor].freeze

  WAITING_TEXT_PATTERNS = [
    /notify me automatically/i,
    /completion notification/i,
    /they'?ll notify/i,
    /\bI'?ll wait\b/i,
    /wait(?:ing)? for .*(?:background|command|test|suite|process).*(?:finish|complete|notification|notify)/i,
    /schedule(?:d)? (?:a )?wakeup/i,
    /ScheduleWakeup/i,
    /schedule_wakeup/i
  ].freeze

  def self.detect?(run) = new(run).detect?

  def initialize(run)
    @run = run
  end

  def detect?
    return false if transcript.blank?

    schedule_wakeup_used? || (background_command_used? && waiting_text_present?)
  end

  private

  attr_reader :run

  def transcript
    @transcript ||= run.reload.provider_session&.transcript_jsonl.to_s
  end

  def events
    @events ||= ClaudeTranscript.new(transcript).events.to_a
  end

  def tool_uses
    events.select { |event| event.kind == :tool_use }
  end

  def assistant_text
    @assistant_text ||= events
      .select { |event| event.kind == :assistant_text }
      .map { |event| event.data[:text].to_s }
      .join("\n")
  end

  def schedule_wakeup_used?
    tool_uses.any? { |event| event.data[:name].to_s.match?(/schedule_wakeup|ScheduleWakeup/i) } ||
      assistant_text.match?(/schedule_wakeup|ScheduleWakeup/i)
  end

  def background_command_used?
    tool_uses.any? do |event|
      name = event.data[:name].to_s
      next false unless BACKGROUND_TOOL_NAMES.include?(name) || name.end_with?("command_execution")

      input = event.data[:input]
      background_flag?(input) || background_shell_command?(command_text(input))
    end
  end

  def background_flag?(input)
    return false unless input.respond_to?(:[])

    input["run_in_background"] == true ||
      input[:run_in_background] == true ||
      input["background"] == true ||
      input[:background] == true
  end

  def command_text(input)
    return "" unless input.respond_to?(:[])

    input["command"].presence ||
      input[:command].presence ||
      input["cmd"].presence ||
      input[:cmd].presence ||
      ""
  end

  def background_shell_command?(command)
    text = command.to_s
    text.match?(/(?:^|[;&|]\s*)(?:nohup|setsid)\b/i) ||
      text.match?(/\b(?:disown|tmux|screen)\b/i) ||
      text.match?(/(?:^|[^&>])&(?![>&])/)
  end

  def waiting_text_present?
    WAITING_TEXT_PATTERNS.any? { |pattern| assistant_text.match?(pattern) }
  end
end
