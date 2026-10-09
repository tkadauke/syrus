# Shared enable/disable actions for the admin Plugins controllers (bearer-token
# Api::V1::Admin::PluginsController and session-auth Api::V1::App::Admin::PluginsController).
# Enabling a plugin cascades to enable its depends_on chain (silent, additive).
# Disabling a plugin with currently-enabled dependents (transitively) returns a
# confirmation payload instead of disabling; passing confirm_cascade=true on a
# retry disables the plugin and every one of those dependents together.
#
# Includers must provide `find_plugin_record` and `render_error` (the latter
# comes from JsonErrorRendering via the shared BaseControllers).
module AdminPluginCascadeActions
  extend ActiveSupport::Concern

  def enable
    plugin = find_plugin_record
    manifests = Syrus::PluginRegistry.all_plugins
    manifest = manifests.find { |candidate| candidate.name == plugin.name }
    dependency_names = manifest ? ::Admin::PluginDependencyGraph.new(manifests).dependencies_for(manifest.name) : []
    blocked_experimental = blocked_experimental_plugins(manifests, [ plugin.name, *dependency_names ])
    if blocked_experimental.any?
      render json: {
        error: {
          code: "beta_mode_not_enabled",
          message: "This plugin is available in this Syrus build, but this instance has not enabled beta mode."
        },
        blocked_experimental_plugins: blocked_experimental.map { |blocked| { name: blocked.name, display_name: blocked.display_name.presence || blocked.name.to_s.titleize } },
        message: "This plugin is available in this Syrus build, but this instance has not enabled beta mode."
      }, status: :unprocessable_content
      return
    end

    ActiveRecord::Base.transaction do
      plugin.update!(enabled: true)
      PluginRecord.where(name: dependency_names).find_each do |record|
        record.update!(enabled: true) unless record.enabled?
      end
    end

    render json: ::Admin::PluginsPayload.new.as_json
  end

  def disable
    plugin = find_plugin_record
    manifest = Syrus::PluginRegistry.all_plugins.find { |candidate| candidate.name == plugin.name }
    ::Admin::PluginDisableGuard.ensure_disableable!(manifest) if manifest

    dependents = manifest ? ::Admin::PluginDisableGuard.dependents_for(manifest) : []
    if dependents.any? && !confirm_cascade?
      render json: { requires_confirmation: true, plugin_name: plugin.name, dependents: dependents }
      return
    end

    ActiveRecord::Base.transaction do
      plugin.update!(enabled: false)
      PluginRecord.where(name: dependents).find_each { |record| record.update!(enabled: false) }
    end

    render json: ::Admin::PluginsPayload.new.as_json
  rescue ActiveRecord::RecordInvalid => e
    render_error("plugin_not_disableable", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
  rescue ::Admin::PluginDisableGuard::Blocked => e
    render_error("plugin_in_use", e.message, status: :conflict)
  end

  private

  def confirm_cascade?
    ActiveModel::Type::Boolean.new.cast(params[:confirm_cascade])
  end

  def blocked_experimental_plugins(manifests, names)
    return [] if AppSetting.beta_mode_enabled?

    by_name = manifests.index_by(&:name)
    names.filter_map { |name| by_name[name] }.select(&:experimental?)
  end
end
