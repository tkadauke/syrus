module K8sCluster
  # Parses Kubernetes resource quantity strings (e.g. "250m", "23148330n",
  # "512Mi", "128974848") into plain integers Overview can sum and compare -
  # just the handful of suffixes CPU/memory metrics actually use in
  # practice, not the full quantity grammar Kubernetes itself accepts.
  module ResourceQuantity
    BINARY_SUFFIXES = { "Ki" => 1024, "Mi" => 1024**2, "Gi" => 1024**3, "Ti" => 1024**4, "Pi" => 1024**5, "Ei" => 1024**6 }.freeze
    DECIMAL_SUFFIXES = { "K" => 1000, "M" => 1000**2, "G" => 1000**3, "T" => 1000**4, "P" => 1000**5, "E" => 1000**6 }.freeze

    module_function

    # Returns millicores (1000m == 1 vCPU).
    def cpu_millicores(value)
      return 0 if value.blank?

      if value.end_with?("n")
        (value.to_f / 1_000_000).round
      elsif value.end_with?("u")
        (value.to_f / 1_000).round
      elsif value.end_with?("m")
        value.to_i
      else
        (value.to_f * 1000).round
      end
    end

    # Returns bytes.
    def memory_bytes(value)
      return 0 if value.blank?

      binary_suffix = BINARY_SUFFIXES.keys.find { |suffix| value.end_with?(suffix) }
      decimal_suffix = DECIMAL_SUFFIXES.keys.find { |suffix| value.end_with?(suffix) } unless binary_suffix
      suffix = binary_suffix || decimal_suffix

      return value.to_i unless suffix

      multiplier = BINARY_SUFFIXES[suffix] || DECIMAL_SUFFIXES[suffix]
      value.delete_suffix(suffix).to_i * multiplier
    end
  end
end
