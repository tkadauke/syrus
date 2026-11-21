require_relative "../../lib/syrus/plugin_gemspec"

Syrus.plugin_gemspec(__FILE__).tap do |spec|
  spec.metadata["requires_syrus"] = ">= 0.1.16"
end
