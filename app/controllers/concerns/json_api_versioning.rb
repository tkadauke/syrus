module JsonApiVersioning
  extend ActiveSupport::Concern

  def render(*args, **options, &block)
    if options[:json].is_a?(Hash)
      options[:json] = ApiVersion.envelope(options[:json])
    end

    super(*args, **options, &block)
  end
end
