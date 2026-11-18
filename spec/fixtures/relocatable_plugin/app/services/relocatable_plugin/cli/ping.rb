module RelocatablePlugin
  module Cli
    class Ping < Syrus::Plugin::CliCommandHandler
      def call(args:, flags:, user:)
        self.class.text("external plugin command executed for #{user.email_address}")
      end
    end
  end
end
