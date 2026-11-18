module Syrus
  module Host
    # Stable base class for plugin-owned Active Record models.
    class ApplicationRecord < ::ApplicationRecord
      self.abstract_class = true
    end
  end
end
