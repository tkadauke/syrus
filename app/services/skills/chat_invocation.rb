module Skills
  # Resolves a chat message's text as a possible `/skill-name key=value ...`
  # slash-command skill invocation, scoped to the chat's attached
  # repository. Centralizes the whole go/no-go gate — unrecognized text,
  # unknown skill, invalid args, Coding Mode required — so ChatTurnJob only
  # has to branch on `status`.
  #
  # Slash-command skill execution reuses the existing Coding Mode chat turn
  # machinery (writable checkout, direct command execution) rather than a
  # second sandboxed path, so a skill that needs to do more than answer a
  # question requires Coding Mode; this only decides whether that's true
  # and, if so, hands back the resolved Skills::Resolution for ChatTurnJob
  # to render and provenance-record. It never executes anything itself.
  class ChatInvocation
    Result = Data.define(:status, :resolution, :args, :message)

    def self.resolve(chat_session:, text:, client: nil)
      new(chat_session: chat_session, text: text, client: client).resolve
    end

    def initialize(chat_session:, text:, client: nil)
      @chat_session = chat_session
      @text = text
      @client = client
    end

    def resolve
      match = SlashCommand.parse(@text)
      return not_a_command unless match

      repository = @chat_session.repository
      return not_a_command unless repository

      args = SlashCommand.parse_args(match.raw_args)
      resolution = resolve_skill(repository, match.name)
      return unknown_skill(match.name, repository) unless resolution

      begin
        ParameterSchema.validate!(resolution.definition.parameters, args)
      rescue ParameterSchema::ValidationError => e
        return invalid_args(resolution, args, e.message)
      end

      return coding_mode_required(resolution, args) unless coding_mode_active?

      Result.new(status: :ready, resolution: resolution, args: args, message: nil)
    end

    private

    def resolve_skill(repository, name)
      Skills.for(repository: repository, name: name, user: @chat_session.user, client: @client)
    rescue Skills::NotFoundError, ArgumentError
      nil
    end

    def coding_mode_active?
      Feature.coding_mode_enabled? && @chat_session.coding? && @chat_session.repository.present?
    end

    def not_a_command
      Result.new(status: :not_a_command, resolution: nil, args: nil, message: nil)
    end

    def unknown_skill(name, repository)
      Result.new(
        status: :unknown_skill,
        resolution: nil,
        args: nil,
        message: "No skill named `/#{name}` is available for #{repository.slug}. " \
                 "Check this chat's slash-command list for the skills available here."
      )
    end

    def invalid_args(resolution, args, errors)
      Result.new(
        status: :invalid_args,
        resolution: resolution,
        args: args,
        message: "`/#{resolution.definition.name}` needs valid arguments: #{errors}"
      )
    end

    def coding_mode_required(resolution, args)
      Result.new(
        status: :coding_mode_required,
        resolution: resolution,
        args: args,
        message: "`/#{resolution.definition.name}` runs a skill, which executes " \
                  "within this chat's Coding Mode workspace. Enable Coding Mode for " \
                  "this chat, then run the command again."
      )
    end
  end
end
