require "../spec_helper"

describe "App::Controllers::Metrics" do
  it "rejects missing and invalid API keys" do
    get "/api/metrics"
    response.status_code.should eq(401)
    get "/api/metrics", headers: HTTP::Headers{"X-Api-Key" => "invalid"}
    response.status_code.should eq(401)
  end

  it "exports zero totals for a user without links" do
    user = create_test_user
    get "/api/metrics", headers: HTTP::Headers{"X-Api-Key" => user.api_key.to_s}
    response.status_code.should eq(200)
    response.headers["Content-Type"].should eq("text/plain; version=0.0.4; charset=utf-8")
    response.headers["Cache-Control"].should eq("no-store")
    response.body.should contain("# TYPE bit_clicks gauge\nbit_clicks 0\n")
    response.body.should contain("bit_links 0\n")
  end

  it "aggregates persisted clicks and only exposes the authenticated user's links" do
    user = create_test_user
    link = create_test_link(user, "https://example.com/metrics")
    empty_link = create_test_link(user, "https://example.com/empty")
    2.times { create_test_click(link) }
    other_link = create_test_link(create_test_user, "https://example.com/private")
    create_test_click(other_link)

    get "/api/metrics", headers: HTTP::Headers{"X-Api-Key" => user.api_key.to_s}
    response.status_code.should eq(200)
    response.body.should contain("bit_links 2\n")
    response.body.should contain("bit_clicks 2\n")
    response.body.should contain("bit_link_clicks{slug=\"#{link.slug}\"} 2\n")
    response.body.should contain("bit_link_clicks{slug=\"#{empty_link.slug}\"} 0\n")
    response.body.should_not contain(other_link.slug.to_s)
    response.body.should contain("bit_clicks_by_country{country=\"US\"} 2\n")
    response.body.should contain("bit_clicks_by_browser{browser=\"Firefox\"} 2\n")
    response.body.should contain("bit_clicks_by_os{os=\"Mac OS X\"} 2\n")
    response.body.should contain("bit_clicks_by_referer{referer=\"example.com\"} 2\n")

    delete_test_link(link.id.as(Int64))
    get "/api/metrics", headers: HTTP::Headers{"X-Api-Key" => user.api_key.to_s}
    response.body.should contain("bit_clicks 0\n")
    response.body.should contain("bit_links 1\n")
  end

  it "escapes label values and handles missing dimensions" do
    user = create_test_user
    link = create_test_link(user, "https://example.com/escaping")
    click = create_test_click(link)
    referer = "campaign\\name\"quoted\nnext"
    App::Lib::Database.raw_exec("UPDATE clicks SET referer = ?, country = NULL, browser = NULL, os = NULL WHERE id = ?", referer, click.id)

    get "/api/metrics", headers: HTTP::Headers{"X-Api-Key" => user.api_key.to_s}
    response.body.should contain("bit_clicks_by_referer{referer=\"campaign\\\\name\\\"quoted\\nnext\"} 1\n")
    response.body.should contain("bit_clicks_by_country{country=\"\"} 1\n")
    response.body.should contain("bit_clicks_by_browser{browser=\"\"} 1\n")
    response.body.should contain("bit_clicks_by_os{os=\"\"} 1\n")
  end
end
