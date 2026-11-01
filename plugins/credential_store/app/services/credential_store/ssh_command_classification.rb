module CredentialStore
  class SshCommandClassification
    READ = {
      operation: "ssh.execute/read@v1",
      effects: %i[network_read confidential_read credential_use operational],
      risk: :high,
      confidence: :certain
    }.freeze
    RISKY = {
      operation: "ssh.execute/risky@v1",
      effects: %i[network_read confidential_read credential_use external_write privilege_change operational destructive irreversible],
      risk: :critical,
      confidence: :certain
    }.freeze

    class Read
      def self.match?(arguments)
        source = arguments.to_h.with_indifferent_access
        source[:allow_risky_command] != true && !SshExec::RiskyCommandClassifier.risky?(source[:command])
      end

      def self.result = READ
    end

    class Risky
      def self.match?(_arguments) = true
      def self.result = RISKY
    end

    STRATEGIES = [ Read, Risky ].freeze

    def self.call(arguments)
      return RISKY.merge(confidence: :ambiguous) if arguments.to_h.with_indifferent_access[:command].blank?

      STRATEGIES.find { |strategy| strategy.match?(arguments) }.result
    rescue StandardError
      RISKY.merge(confidence: :ambiguous)
    end
  end
end
