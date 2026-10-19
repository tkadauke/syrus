class ExecutionProfile
  PROFILES = {
    "linux" => { "os" => [ "linux" ] },
    "macos_desktop" => { "os" => [ "macos" ], "arch" => [ "arm64" ] },
    "ios_xcode" => {
      "os" => [ "macos" ], "arch" => [ "arm64" ],
      "toolchain" => [ "xcode" ], "runtime" => [ "ios_simulator" ]
    }
  }.freeze

  def self.fetch(name)
    capabilities = PROFILES.fetch(name.to_s) { raise ArgumentError, "unknown execution profile #{name.inspect}" }
    new(name.to_s, capabilities)
  end

  attr_reader :name, :capabilities

  def initialize(name, capabilities)
    @name = name
    @capabilities = PlannedExecutionRequirement.normalize_capabilities(capabilities)
  end
end
