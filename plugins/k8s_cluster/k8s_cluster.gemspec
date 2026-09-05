require_relative "../../lib/syrus/plugin_gemspec"

Syrus.plugin_gemspec(__FILE__) do |spec|
  spec.add_dependency "kubeclient", "~> 4.13"
end
