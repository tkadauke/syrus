module Syrus
  class PluginHostSurface
    # Keep exceptions rare and document why a stable public contract cannot be
    # exposed. Entries are exact constant names; wildcard exemptions are not
    # supported. There are currently no exceptions.
    INTENTIONAL_INTERNAL_REFERENCES = {}.freeze

    def allowed_internal?(name) = INTENTIONAL_INTERNAL_REFERENCES.key?(name.to_s)
  end
end
