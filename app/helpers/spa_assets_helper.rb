module SpaAssetsHelper
  SPA_ENTRY_ASSET_PATTERN = /\Aspa-entry-[A-Za-z0-9_-]+\.digested\.js\z/

  def spa_asset_version
    ERB::Util.url_encode(SyrusVersion.current.presence || Rails.application.config.assets.version)
  end

  def spa_stylesheet_link_tags
    append_spa_asset_version(stylesheet_link_tag("tailwind"))
  end

  def spa_javascript_include_tag(source, **options)
    append_spa_asset_version(javascript_include_tag(source, **options))
  end

  def spa_asset_tag(tag)
    append_spa_asset_version(tag)
  end

  def spa_entry_asset_name
    Dir.children(Rails.root.join("app/assets/builds"))
      .grep(SPA_ENTRY_ASSET_PATTERN)
      .max_by { |name| Rails.root.join("app/assets/builds", name).mtime }
  rescue Errno::ENOENT
    nil
  end

  def spa_entry_javascript_include_tag(**options)
    entry_asset_name = spa_entry_asset_name
    return "".html_safe if entry_asset_name.blank?

    spa_javascript_include_tag(entry_asset_name, **options)
  end

  private

  def append_spa_asset_version(tags)
    version = spa_asset_version
    return tags if version.blank?

    tags.to_s.gsub(/(href|src)="([^"]+)"/) do |match|
      attr = Regexp.last_match(1)
      path = Regexp.last_match(2)
      next match unless path.start_with?("/assets/")
      next match if content_hashed_spa_asset_path?(path)

      separator = path.include?("?") ? "&" : "?"
      %(#{attr}="#{path}#{separator}v=#{version}")
    end.html_safe
  end

  def content_hashed_spa_asset_path?(path)
    filename = File.basename(path.split(/[?#]/, 2).first)

    filename.include?(".digested.") || filename.match?(/\A.+-[0-9a-f]{8,}(?:\.[^.]+)+\z/i)
  end
end
