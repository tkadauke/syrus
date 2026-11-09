class CodexAuth
  # One object per User#codex_auth_mode; callers ask the mode instead of
  # branching on the mode string.
  module Modes
    class Base
      def refreshes_login? = false
      def prepare(_auth) = raise(NotImplementedError)
    end

    class ApiKey < Base
      def prepare(auth) = auth.send(:prepare_api_key)
    end

    class ChatgptLogin < Base
      def refreshes_login? = true
      def prepare(auth) = auth.send(:prepare_chatgpt_login)
    end

    REGISTRY = { "api_key" => ApiKey.new, "chatgpt_login" => ChatgptLogin.new }.freeze

    def self.for(name)
      REGISTRY.fetch(name.to_s) { raise Error, "Unknown Codex auth mode: #{name.inspect}" }
    end
  end
end
