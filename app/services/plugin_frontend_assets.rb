require "digest"

class PluginFrontendAssets
  Asset = Data.define(:plugin_name, :kind, :path, :content_type, :hash)

  CONTENT_TYPES = {
    bundle: "text/javascript; charset=utf-8",
    css: "text/css; charset=utf-8"
  }.freeze

  def self.entries
    enabled_manifests.filter_map do |manifest|
      bundle = asset_for(manifest, :bundle)
      next unless bundle

      css = asset_for(manifest, :css)
      hash = Digest::SHA256.hexdigest([ bundle, css ].compact.map { |asset| File.binread(asset.path) }.join)
      {
        name: manifest.name,
        bundle_url: url_for(manifest.name, :bundle, hash),
        css_url: (url_for(manifest.name, :css, hash) if css),
        hash: hash
      }.compact
    end
  end

  def self.find(plugin_name, kind)
    kind = kind.to_s.to_sym
    return unless CONTENT_TYPES.key?(kind)

    manifest = enabled_manifests.find { |candidate| candidate.name == plugin_name }
    return unless manifest

    asset = asset_for(manifest, kind)
    return unless asset

    hash = entries.find { |entry| entry[:name] == plugin_name }&.fetch(:hash, nil)
    asset.with(hash: hash)
  end

  def self.asset_for(manifest, kind)
    relative_path = manifest.metadata.dig(:frontend, kind) || manifest.metadata.dig("frontend", kind.to_s)
    return if relative_path.blank? || manifest.plugin_root.blank?

    root = Pathname.new(manifest.plugin_root).realpath
    candidate = root.join(relative_path.to_s)
    resolved = candidate.realpath
    return unless resolved.file? && resolved.to_s.start_with?("#{root}/")

    Asset.new(plugin_name: manifest.name, kind: kind, path: resolved, content_type: CONTENT_TYPES.fetch(kind), hash: nil)
  rescue Errno::ENOENT, Errno::EACCES
    nil
  end
  private_class_method :asset_for

  def self.enabled_manifests
    health = Syrus::PluginRegistry.health
    Syrus::PluginRegistry.all_plugins.select { |manifest| manifest.enabled? && health.healthy?(manifest.name) }
  end
  private_class_method :enabled_manifests

  def self.url_for(plugin_name, kind, hash)
    "/api/v1/app/plugin_frontends/#{CGI.escapeURIComponent(plugin_name)}/#{kind}?v=#{hash}"
  end
  private_class_method :url_for
end
