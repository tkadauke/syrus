module SpaAssetsHelper
  def spa_stylesheet_link_tags
    append_spa_asset_version(stylesheet_link_tag(:app))
  end

  def spa_javascript_include_tag(source, **options)
    append_spa_asset_version(javascript_include_tag(source, **options))
  end

  def spa_asset_tag(tag)
    append_spa_asset_version(tag)
  end

  private

  def append_spa_asset_version(tags)
    version = ERB::Util.url_encode(SyrusVersion.current.presence || Rails.application.config.assets.version)
    return tags if version.blank?

    tags.to_s.gsub(/(href|src)="([^"]+)"/) do |match|
      attr = Regexp.last_match(1)
      path = Regexp.last_match(2)
      next match unless path.start_with?("/assets/")

      separator = path.include?("?") ? "&" : "?"
      %(#{attr}="#{path}#{separator}v=#{version}")
    end.html_safe
  end
end
