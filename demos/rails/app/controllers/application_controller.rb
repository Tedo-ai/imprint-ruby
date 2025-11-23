class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Protect from CSRF attacks
  protect_from_forgery with: :exception

  # Skip CSRF for API endpoints
  skip_before_action :verify_authenticity_token, if: -> { request.format.json? }
end
