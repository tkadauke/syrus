module Skills
  # Parses a chat message's raw text as a `/skill-name key=value ...`
  # slash-command invocation. Purely syntactic — resolving the name against
  # a repository's skill set is Skills::ChatInvocation's job. The whole
  # message must be the command (name plus trailing args), so ordinary
  # prose that merely contains a slash never matches.
  module SlashCommand
    # Name charset mirrors Skills::NAME_PATTERN (without the anchors).
    PATTERN = /\A\/([a-z0-9][a-z0-9_-]*)(?:\s+(.*))?\z/m
    ARG_PATTERN = /([a-zA-Z_][a-zA-Z0-9_]*)=(?:"([^"]*)"|'([^']*)'|(\S*))/m

    Match = Data.define(:name, :raw_args)

    module_function

    def parse(text)
      return nil if text.blank?

      match = PATTERN.match(text.to_s.strip)
      return nil unless match

      Match.new(name: match[1], raw_args: match[2].to_s)
    end

    # "key=value key2=\"quoted value\"" -> { "key" => "value", "key2" => "quoted value" }
    def parse_args(raw_args)
      raw_args.to_s.scan(ARG_PATTERN).each_with_object({}) do |(key, dquoted, squoted, bare), args|
        args[key] = dquoted || squoted || bare.to_s
      end
    end
  end
end
