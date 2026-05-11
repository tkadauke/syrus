class SlashCommandParser
  APPROVE = %w[/approve /approved /accept /accepted /lgtm].freeze
  UNAPPROVE = %w[/unapprove /cancel].freeze
  REJECT = %w[/reject /rejected].freeze
  COMMANDS = (APPROVE + UNAPPROVE + REJECT).freeze

  Result = Struct.new(:command, :family, keyword_init: true) do
    def approve? = family == "approve"
    def unapprove? = family == "unapprove"
    def reject? = family == "reject"
  end

  def self.parse(body)
    new(body).parse
  end

  def initialize(body)
    @body = body.to_s
  end

  def parse
    last = nil
    in_fence = false

    @body.each_line do |line|
      scan = line.dup
      if scan.include?("```")
        before, _sep, after = scan.partition("```")
        last = command_for(before) || last unless in_fence
        in_fence = !in_fence
        scan = after
      end
      next if in_fence

      last = command_for(strip_inline_code(scan)) || last
    end

    last
  end

  private

  def strip_inline_code(line)
    line.gsub(/`[^`\n]*`/, "")
  end

  def command_for(line)
    match = line.match(/\A\s*(\/[a-z]+)\b/i)
    return nil unless match

    command = match[1].downcase
    return nil unless COMMANDS.include?(command)

    Result.new(command: command, family: family_for(command))
  end

  def family_for(command)
    return "approve" if APPROVE.include?(command)
    return "unapprove" if UNAPPROVE.include?(command)
    "reject"
  end
end
