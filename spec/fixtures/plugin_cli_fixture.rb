module PluginCliFixture
  class Handler < Syrus::Plugin::CliCommandHandler
    def call(args:, flags:, user:) = self.class.text("#{args.fetch(0)}, #{user.email_address}#{flags['loud'] ? '!' : ''}")
  end

  class TableHandler < Syrus::Plugin::CliCommandHandler
    def call(args:, flags:, user:) = self.class.table(columns: %w[name active], rows: [ [ user.email_address, flags.fetch("active", false) ] ])
  end

  class JsonHandler < Syrus::Plugin::CliCommandHandler
    def call(args:, flags:, user:) = self.class.json({ "args" => args, "flags" => flags, "user_id" => user.id })
  end

  class UnauthorizedHandler < Syrus::Plugin::CliCommandHandler
    def call(args:, flags:, user:) = raise(Pundit::NotAuthorizedError)
  end

  class ExplodingHandler < Syrus::Plugin::CliCommandHandler
    def call(args:, flags:, user:) = raise("fixture failure")
  end
end
