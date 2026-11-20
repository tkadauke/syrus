module {{MODULE_NAME}}
  module Cli
    class Hello < Syrus::Plugin::CliCommandHandler
      def call(args:, flags:, user:)
        self.class.text("Hello from {{DISPLAY_NAME}}")
      end
    end
  end
end
