module App::Middlewares
  class Metrics < Kemal::Handler
    def call(env)
      return call_next(env) if env.request.path.rstrip('/') == "/metrics"

      started = Time.instant
      begin
        call_next(env)
      ensure
        # This handler wraps Kemal's exception handler, so errors have their
        # final HTTP status by the time they are recorded here.
        method = env.request.method
        method = "OTHER" unless {"GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "CONNECT", "TRACE", "QUERY"}.includes?(method)
        route = env.route_found? ? env.route.path : "unmatched"
        App::Lib::ServiceMetrics.observe(method, route, env.response.status_code, (Time.instant - started).total_seconds)
      end
    end
  end
end
