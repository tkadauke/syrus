module RuntimeImages
  module OciRegistry
    # A username/secret pair for one role. The secret never appears in
    # inspect/to_s output, so logging a credential or an object holding one
    # cannot leak it.
    class Credential
      attr_reader :username

      def initialize(username:, secret:)
        @username = username.to_s
        @secret = secret.to_s
        freeze
      end

      def basic_header = "Basic #{["#{@username}:#{@secret}"].pack('m0')}"
      def secret_values = [@secret].reject(&:empty?)
      def inspect = "#<#{self.class.name} username=#{@username.inspect} secret=[REDACTED]>"
      alias_method :to_s, :inspect
    end
  end
end
