# Shared `{ "error": { "code": "...", "message": "..." } }` error envelope
# used by the API base controllers.
module JsonErrorRendering
  private

  def render_error(code, message, status:)
    render json: { error: { code: code, message: message } }, status: status
  end
end
