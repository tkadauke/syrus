module Filters
  module Chips
    module Jobs
      # `Job#delivery_track` is a plain nullable string column (see
      # config/syrus_docs/delivery_tracks.md) — values are repository-
      # configured track names, not a fixed set, so this chip declares no
      # static `values()` and falls back to free-text entry in the chip bar.
      class DeliveryTrack < EnumColumn
        filter_name "delivery_track"
        label "Delivery track"
        column :delivery_track
      end
    end
  end
end
