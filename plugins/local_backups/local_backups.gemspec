require_relative "../../lib/syrus/plugin_gemspec"

Syrus.plugin_gemspec(__FILE__).tap do |spec|
  spec.files << "bin/syrus-recovery"
  spec.bindir = "bin"
  spec.executables = [ "syrus-recovery" ]
end
