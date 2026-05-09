# frozen_string_literal: true

require_relative "app"

# Fragments under assets/private/ are read by Ruby only (e.g. AboutPage). With
# Sinatra's default static handler, they'd still be reachable as /private/*;
# block that so local Rack matches Lambda (only ASSET_ROUTES keys are public).
class DenyAssetsPrivate
  def initialize(app)
    @app = app
  end

  def call(env)
    path = env["PATH_INFO"].to_s
    if path == "/private" || path.start_with?("/private/")
      return [404, { "Content-Type" => "text/plain; charset=utf-8" }, ["not found"]]
    end

    @app.call(env)
  end
end

run(
  Rack::Builder.new do
    use DenyAssetsPrivate
    run Sinatra::Application
  end
)
