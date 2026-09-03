module Syrus
  module Plugin
    # Marker interface for plugin-contributed panels rendered inside an
    # existing core page.
    #
    # Admin pages, sidebar pages, and repo-page tabs all give a plugin a whole
    # page. A ui_slot gives it a section of one — the throughput panel on the
    # repository detail page, the sccache card on the job detail page. Without
    # this, a feature that reads as part of a core page can only be extracted
    # by turning it into a separate tab, which changes the product to suit the
    # plugin boundary.
    #
    # Providers expose:
    #
    #   .ui_slots(slot:, context:) => [{ id:, component:, order: }]
    #
    # `slot` is a name from Syrus::Plugin::UiSlot::SLOTS. `context` carries
    # whatever the host page has resolved (e.g. { repository:, user: } or
    # { job:, user: }), so a provider can decide per record whether to render.
    # Return [] to render nothing.
    module UiSlot
      # Declared here rather than as free-form strings so a typo in a plugin
      # fails loudly instead of silently rendering nowhere.
      SLOTS = %w[
        repository.detail
        job.detail
      ].freeze

      def self.valid_slot?(slot) = SLOTS.include?(slot.to_s)
    end
  end
end
