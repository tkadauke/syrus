require_relative "../../lib/syrus/plugin_gemspec"

Syrus.plugin_gemspec(__FILE__) do |spec|
  spec.add_dependency "puma", ">= 5.0"
end
