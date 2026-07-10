module Syrus
  module Plugin
    # Marker module for plugin-provided input source STI classes.
    #
    # Including this module makes the type visible in the repository settings UI
    # when the plugin is registered as an :input_source extension point.
    #
    # Classes must also implement the full InputSource interface (defined by
    # EPIC-155): #poll!, #validate_credentials!, #config_schema, #dedup_key.
    module InputSource
    end
  end
end
