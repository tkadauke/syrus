require "shellwords"

module GraderCommandSpans
  class Plan
    Fragment = Data.define(:sequence, :command, :operator_before, :name)

    MAX_FRAGMENTS = 20
    MAX_COMMAND_EXCERPT = 1024

    LABELS = [
      [ /\bbundle\s+check\b/, "bundle check" ],
      [ /\bbundle\s+install\b/, "bundle install" ],
      [ /\b(?:bin\/rails|rails)\s+db:test:prepare\b/, "db:test:prepare" ],
      [ /\b(?:bin\/)?rspec\b/, "rspec" ],
      [ /\b(?:bin\/)?rubocop\b/, "rubocop" ],
      [ /\b(?:npm|yarn|pnpm)\s+(?:run\s+)?(?:test|test:react|vitest)\b|\bvitest\b|\bjest\b/, "frontend tests" ],
      [ /\b(?:npm|yarn|pnpm)\s+(?:run\s+)?(?:build|typecheck)\b|\btsc\s+--noEmit\b/, "frontend build" ],
      [ /\bwebsite\/|--prefix\s+website|\b(?:npm|yarn|pnpm)\s+(?:--prefix\s+website\s+)?(?:run\s+)?build\b/, "website build" ],
      [ /\bcheck-migrations?\b/, "migration checks" ],
      [ /\bcheck-eager-load\b/, "eager load check" ],
      [ /\bcheck-production-build-boot\b/, "production build boot" ]
    ].freeze

    attr_reader :command, :fragments, :fallback_reason

    def self.for(command)
      new(command)
    end

    def initialize(command)
      @command = command.to_s
      @fragments, @fallback_reason = build_fragments
    end

    def instrumentable?
      fallback_reason.nil? && fragments.size > 1
    end

    def shell_command
      return command unless instrumentable?

      fragments.map do |fragment|
        call = "__syrus_span #{fragment.sequence} #{Shellwords.escape(fragment.name)} #{Shellwords.escape(fragment.command)}"
        fragment.operator_before ? "#{fragment.operator_before} #{call}" : call
      end.join(" ")
    end

    private

    def build_fragments
      return [ [ whole_command_fragment ], "contains shell control flow" ] if shell_control_flow?

      tokens, reason = split_top_level
      return [ [ whole_command_fragment ], reason ] if reason

      commands = tokens.select { |token| token[:type] == :command }
      return [ [ whole_command_fragment ], "no top-level shell operators" ] if commands.size <= 1
      return [ [ whole_command_fragment ], "too many top-level command fragments" ] if commands.size > MAX_FRAGMENTS

      sequence = 0
      fragments = tokens.filter_map do |token|
        next unless token[:type] == :command

        sequence += 1
        Fragment.new(
          sequence: sequence,
          command: token[:value],
          operator_before: token[:operator_before],
          name: label_for(token[:value], sequence)
        )
      end
      [ fragments, nil ]
    end

    def whole_command_fragment
      Fragment.new(sequence: 1, command: excerpt(command), operator_before: nil, name: label_for(command, 1))
    end

    def label_for(fragment, sequence)
      normalized = fragment.to_s.squish
      match = LABELS.find { |pattern, _label| normalized.match?(pattern) }
      return match.last if match

      words = normalized.gsub(/\A(?:env\s+(?:-[iu]\s+\S+\s+|\S+=\S+\s+)*)/, "")
      first = words.split(/\s+/).first(3).join(" ").presence || "command"
      "#{first} ##{sequence}"
    end

    def split_top_level
      tokens = []
      current = +""
      operator_before = nil
      quote = nil
      escaped = false
      paren_depth = 0
      brace_depth = 0
      bracket_depth = 0
      i = 0

      while i < command.length
        char = command[i]

        if escaped
          current << char
          escaped = false
          i += 1
          next
        end

        if quote
          current << char
          escaped = char == "\\" && quote != "'"
          quote = nil if char == quote
          i += 1
          next
        end

        case char
        when "'", '"'
          quote = char
          current << char
        when "\\"
          escaped = true
          current << char
        when "("
          paren_depth += 1
          current << char
        when ")"
          paren_depth -= 1
          return [ nil, "unbalanced parenthesis" ] if paren_depth.negative?
          current << char
        when "{"
          brace_depth += 1
          current << char
        when "}"
          brace_depth -= 1
          return [ nil, "unbalanced brace" ] if brace_depth.negative?
          current << char
        when "["
          bracket_depth += 1
          current << char
        when "]"
          bracket_depth -= 1
          return [ nil, "unbalanced bracket" ] if bracket_depth.negative?
          current << char
        when "&", "|", ";"
          operator = top_level_operator_at(i, paren_depth, brace_depth, bracket_depth)
          if operator
            fragment = current.strip
            return [ nil, "empty command fragment" ] if fragment.blank?

            tokens << { type: :command, value: fragment, operator_before: operator_before }
            operator_before = operator
            current = +""
            i += operator.length - 1
          else
            current << char
          end
        else
          current << char
        end
        i += 1
      end

      return [ nil, "unterminated quote" ] if quote
      return [ nil, "unbalanced shell grouping" ] unless paren_depth.zero? && brace_depth.zero? && bracket_depth.zero?

      fragment = current.strip
      return [ nil, "empty command fragment" ] if fragment.blank?

      tokens << { type: :command, value: fragment, operator_before: operator_before }
      [ tokens, nil ]
    end

    def shell_control_flow?
      command.match?(/\b(?:case|elif|else|esac|fi|for|function|if|then|until|while)\b/)
    end

    def top_level_operator_at(index, paren_depth, brace_depth, bracket_depth)
      return unless paren_depth.zero? && brace_depth.zero? && bracket_depth.zero?

      two = command[index, 2]
      return two if two == "&&" || two == "||"
      return ";" if command[index] == ";"
    end

    def excerpt(value)
      value.to_s.squish.safe_byteslice(0, MAX_COMMAND_EXCERPT)
    end
  end
end
