class Coworkers::PushFailure
  TRANSIENT_PATTERNS = [ /\b(?:HTTP )?5\d\d\b/i, /Internal Server Error/i, /commit_refs/i,
    /connection (?:reset|timed out)/i, /operation timed out/i, /could not resolve host/i,
    /failed to connect/i, /unexpected disconnect/i ].freeze

  attr_reader :error
  def self.for(error) = TRANSIENT_PATTERNS.any? { |pattern| error.message.match?(pattern) } ? Transient.new(error) : Permanent.new(error)
  def initialize(error) = @error = error
  def transient? = false
  def kind = "permanent"

  Transient = Class.new(self) do
    def transient? = true
    def kind = "transient"
  end
  Permanent = Class.new(self)
end
