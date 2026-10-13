# What a grader declares it can productively use, authored next to its command
# in `.syrus.yml`:
#
#   grade:
#     steps:
#       - type: rspec
#         resources:
#           cpu: all        # scales with whatever it is granted
#           cpu_min: 2      # below this, parallelism buys nothing
#           memory: 6GB     # working set at full width
#
# A request is a claim about the work, not a reservation -- GraderResourceGrant
# resolves it against the host. Deliberately NOT part of the grader
# fingerprint: a request changes how fast a grader runs, never what it
# asserts, so hashing it would discard cached green grades on a parallelism
# tweak. See docs/plans/grader-resource-grants.md.
class GraderResourceRequest < Data.define(:cpu, :cpu_min, :memory_bytes)
  KEYS = %w[cpu cpu_min memory].freeze
  ALL = "all".freeze
  # A grader that declares nothing is assumed serial. That is the conservative
  # reading and the one that makes the pool work: an undeclared grader claims
  # a single core, so a declared `cpu: all` grader can take the rest instead of
  # dividing the host by a presumed worker width.
  DEFAULT_CPU = 1
  MAX_CPU = 1024
  BYTE_UNITS = {
    "b" => 1,
    "k" => 1024, "kb" => 1024, "kib" => 1024,
    "m" => 1024**2, "mb" => 1024**2, "mib" => 1024**2,
    "g" => 1024**3, "gb" => 1024**3, "gib" => 1024**3,
    "t" => 1024**4, "tb" => 1024**4, "tib" => 1024**4
  }.freeze
  SIZE_PATTERN = /\A(\d+(?:\.\d+)?)\s*([a-z]*)\z/

  def initialize(cpu: DEFAULT_CPU, cpu_min: 1, memory_bytes: nil)
    super(cpu: cpu, cpu_min: cpu_min, memory_bytes: memory_bytes)
  end

  # Raises ArgumentError on malformed input; SyrusYml turns that into a
  # ParseError with the config path attached.
  def self.parse(raw)
    return nil if raw.nil?
    raise ArgumentError, "must be a mapping" unless raw.is_a?(Hash)

    raw = raw.deep_stringify_keys
    unknown = raw.keys - KEYS
    raise ArgumentError, "unknown keys #{unknown.sort.join(', ')}; expected #{KEYS.join(', ')}" if unknown.any?

    request = new(
      cpu: parse_cpu(raw["cpu"], "cpu"),
      cpu_min: parse_cpu_min(raw["cpu_min"]),
      memory_bytes: parse_bytes(raw["memory"])
    )
    request.empty? ? nil : request
  end

  def self.from_details(raw)
    return nil if raw.blank?
    return raw if raw.is_a?(GraderResourceRequest)
    return nil unless raw.is_a?(Hash)

    raw = raw.deep_stringify_keys
    cpu = raw["cpu"]
    new(
      cpu: cpu == ALL ? ALL : (Integer(cpu, exception: false) || DEFAULT_CPU),
      cpu_min: Integer(raw["cpu_min"], exception: false) || 1,
      memory_bytes: Integer(raw["memory_bytes"], exception: false)
    )
  end

  def self.parse_cpu(value, label)
    return DEFAULT_CPU if value.nil?
    return ALL if value.to_s.strip.downcase == ALL

    cores = Integer(value.to_s.strip, exception: false)
    raise ArgumentError, "#{label}: must be a positive integer or #{ALL.inspect}" if cores.nil? || !cores.positive?
    raise ArgumentError, "#{label}: must be at most #{MAX_CPU}" if cores > MAX_CPU

    cores
  end
  private_class_method :parse_cpu

  def self.parse_cpu_min(value)
    return 1 if value.nil?

    cores = parse_cpu(value, "cpu_min")
    raise ArgumentError, "cpu_min: must be a positive integer" if cores == ALL

    cores
  end
  private_class_method :parse_cpu_min

  def self.parse_bytes(value)
    return nil if value.nil?
    return positive_bytes(value, value) if value.is_a?(Integer)

    match = SIZE_PATTERN.match(value.to_s.strip.downcase)
    raise ArgumentError, "memory: must be a byte count or a size like 6GB" unless match

    amount, unit = match.captures
    multiplier = unit.empty? ? 1 : BYTE_UNITS[unit]
    raise ArgumentError, "memory: unknown unit #{unit.inspect}" unless multiplier

    positive_bytes((amount.to_f * multiplier).floor, value)
  end
  private_class_method :parse_bytes

  def self.positive_bytes(bytes, original)
    raise ArgumentError, "memory: must be positive, got #{original.inspect}" unless bytes.positive?

    bytes
  end
  private_class_method :positive_bytes

  def unbounded_cpu?
    cpu == ALL
  end

  # A request that asks for exactly the defaults carries no information, so
  # parsing it yields nil and callers keep their own fallbacks.
  def empty?
    cpu == DEFAULT_CPU && cpu_min == 1 && memory_bytes.nil?
  end

  # Upper bound in cores, given what the host could offer at most.
  def cpu_ceiling(host_capacity)
    unbounded_cpu? ? host_capacity : [ cpu, host_capacity ].min
  end

  def to_h
    { "cpu" => cpu, "cpu_min" => cpu_min, "memory_bytes" => memory_bytes }.compact
  end
end
