module App::Lib
  # Only fixed method names, route templates and status codes become labels.
  # Counts and durations reset on restart; database gauges survive restarts.
  module ServiceMetrics
    STARTED = Time.instant
    BUCKETS = {0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0}
    @@mutex = Mutex.new
    @@requests = {} of Tuple(String, String, Int32) => UInt64
    @@buckets = Array(UInt64).new(BUCKETS.size, 0_u64)
    @@count = 0_u64
    @@sum = 0.0

    def self.observe(method : String, route : String, status : Int32, seconds : Float64)
      @@mutex.synchronize do
        key = {method, route, status}
        @@requests[key] = (@@requests[key]? || 0_u64) + 1
        @@count += 1
        @@sum += seconds
        BUCKETS.each_with_index { |bound, i| @@buckets[i] += 1 if seconds <= bound }
      end
    end

    def self.render : String
      String.build do |io|
        {"links", "clicks", "users"}.each do |table|
          io << "# HELP bit_" << table << " Number of stored " << table << " across the service.\n"
          io << "# TYPE bit_" << table << " gauge\n"
          Database.raw_query("SELECT COUNT(*) FROM #{table}") do |rows|
            rows.move_next
            io << "bit_" << table << ' ' << rows.read(Int64) << '\n'
          end
        end
        io << "# HELP bit_uptime_seconds Time since this process started.\n# TYPE bit_uptime_seconds gauge\n"
        io << "bit_uptime_seconds " << (Time.instant - STARTED).total_seconds << '\n'
        @@mutex.synchronize do
          io << "# HELP bit_http_requests_total Completed HTTP requests excluding service scrapes.\n# TYPE bit_http_requests_total counter\n"
          @@requests.each do |(method, route, status), count|
            io << "bit_http_requests_total{method=\"" << method << "\",route=\"" << route << "\",status=\"" << status << "\"} " << count << '\n'
          end
          io << "# HELP bit_http_request_duration_seconds HTTP handler duration excluding service scrapes and asynchronous click persistence.\n# TYPE bit_http_request_duration_seconds histogram\n"
          BUCKETS.each_with_index do |bound, i|
            io << "bit_http_request_duration_seconds_bucket{le=\"" << bound << "\"} " << @@buckets[i] << '\n'
          end
          io << "bit_http_request_duration_seconds_bucket{le=\"+Inf\"} " << @@count << '\n'
          io << "bit_http_request_duration_seconds_sum " << @@sum << '\n'
          io << "bit_http_request_duration_seconds_count " << @@count << '\n'
        end
      end
    end
  end
end
