require "../spec_helper"

# Exercise final status recording after Kemal renders an unhandled exception.
get "/api/metrics-test-error" do
  raise "metrics test error"
end

private def metric_value(body : String, name : String) : Float64
  body.lines.find { |line| line.starts_with?("#{name} ") }.not_nil!.split.last.to_f64
end

describe "service metrics" do
  it "exports service-wide counts without credentials or private analytics" do
    get "/metrics"
    response.status_code.should eq(200)
    before_links = metric_value(response.body, "bit_links")
    before_clicks = metric_value(response.body, "bit_clicks")
    before_users = metric_value(response.body, "bit_users")
    2.times do |i|
      user = create_test_user
      link = create_test_link(user, "https://private.example/#{i}")
      create_test_click(link)
    end
    {"/metrics", "/metrics/"}.each do |path|
      get path
      response.status_code.should eq(200)
      response.headers["Content-Type"].should eq("text/plain; version=0.0.4; charset=utf-8")
      response.headers["Cache-Control"].should eq("no-store")
      metric_value(response.body, "bit_links").should eq(before_links + 2)
      metric_value(response.body, "bit_clicks").should eq(before_clicks + 2)
      metric_value(response.body, "bit_users").should eq(before_users + 2)
      metric_value(response.body, "bit_uptime_seconds").should be >= 0
      response.body.should_not contain("slug=")
      response.body.should_not contain("referer=")
      response.body.should_not contain("private.example")
    end
  end

  it "records completed success, auth, missing route, method and server errors" do
    headers = HTTP::Headers{"X-Api-Key" => create_test_user.api_key.to_s}
    get "/api/ping"
    get "/api/links"
    get "/missing/private-path", headers: headers
    post "/api/ping", headers: headers
    get "/api/metrics-test-error", headers: headers
    response.status_code.should eq(500)
    get "/metrics"
    body = response.body
    body.should contain("bit_http_requests_total{method=\"GET\",route=\"/api/ping\",status=\"200\"} ")
    body.should contain("bit_http_requests_total{method=\"GET\",route=\"/api/links\",status=\"401\"} ")
    body.should contain("bit_http_requests_total{method=\"GET\",route=\"unmatched\",status=\"404\"} ")
    body.should contain("bit_http_requests_total{method=\"POST\",route=\"unmatched\",status=\"405\"} ")
    body.should contain("bit_http_requests_total{method=\"GET\",route=\"/api/metrics-test-error\",status=\"500\"} 1\n")
    body.should_not contain("private-path")
    body.should contain("# TYPE bit_http_request_duration_seconds histogram\n")
    metric_value(body, "bit_http_request_duration_seconds_sum").should be > 0
    count = metric_value(body, "bit_http_request_duration_seconds_count")
    metric_value(body, "bit_http_request_duration_seconds_bucket{le=\"+Inf\"}").should eq(count)
    get "/metrics/"
    metric_value(response.body, "bit_http_request_duration_seconds_count").should eq(count)
  end

  it "keeps histogram buckets cumulative and computes a duration sum and count" do
    get "/metrics"
    before_body = response.body
    App::Lib::ServiceMetrics.observe("GET", "/api/ping", 200, 0.02)
    get "/metrics"
    body = response.body
    {0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0}.each do |bound|
      name = "bit_http_request_duration_seconds_bucket{le=\"#{bound}\"}"
      (metric_value(body, name) - metric_value(before_body, name)).should eq(bound >= 0.02 ? 1 : 0)
    end
    (metric_value(body, "bit_http_request_duration_seconds_count") - metric_value(before_body, "bit_http_request_duration_seconds_count")).should eq(1)
    (metric_value(body, "bit_http_request_duration_seconds_sum") - metric_value(before_body, "bit_http_request_duration_seconds_sum")).should be_close(0.02, 0.000001)
  end
end
