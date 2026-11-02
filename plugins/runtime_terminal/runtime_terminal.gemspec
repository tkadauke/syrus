require_relative "../../lib/syrus/plugin_gemspec"

Syrus.plugin_gemspec(__FILE__) do |spec|
  # Screen#display_width measures East Asian wide and combining characters so
  # the VT grid advances the cursor the way a real terminal does. The gem also
  # arrives transitively via RuboCop, which is development-only -- declaring it
  # here is what keeps it in the production bundle.
  spec.add_dependency "unicode-display_width", "~> 3.3"
end
