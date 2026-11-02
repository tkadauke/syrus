class ExecutionPlacementProfile
  PROFILES = {
    "linux" => {
      "label" => "Linux",
      "capabilities" => { "os" => [ "linux" ] }
    },
    "macos_desktop" => {
      "label" => "macOS desktop",
      "capabilities" => { "os" => [ "macos" ] }
    },
    "ios_xcode" => {
      "label" => "iOS / Xcode",
      "capabilities" => { "os" => [ "macos" ] }
    }
  }.freeze

  attr_reader :name, :label, :capabilities

  def self.find(name)
    definition = PROFILES[name.to_s]
    return unless definition

    new(name.to_s, definition)
  end

  def self.fetch(name)
    find(name) || raise(ArgumentError, "unknown execution placement profile #{name.inspect}")
  end

  def initialize(name, definition)
    @name = name
    @label = definition.fetch("label")
    @capabilities = PlannedExecutionRequirement.normalize_capabilities(definition.fetch("capabilities"))
  end

  def linux? = name == "linux"
end
