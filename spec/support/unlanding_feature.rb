# Helpers for the default-off `unlanding` feature flag. Specs that exercise the
# creation of new unland operations call `enable_unlanding!`; specs for the
# disabled behavior rely on the default (flag unset => off).
module UnlandingFeatureHelpers
  def enable_unlanding!
    set_unlanding!(true)
  end

  def disable_unlanding!
    set_unlanding!(false)
  end

  private

  def set_unlanding!(enabled)
    feature = Feature.find_or_initialize_by(slug: "unlanding")
    feature.update!(category: "Labs", name: "Unlanding", experimental: true, enabled: enabled)
    Feature.clear_enabled_cache!
  end
end

RSpec.configure { |config| config.include UnlandingFeatureHelpers }
