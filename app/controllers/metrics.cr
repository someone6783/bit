module App::Controllers
  class MetricsController < App::Lib::BaseController
    # These are database snapshots, so deletions can decrease their values.
    # Export gauges rather than counters and keep every query scoped to the user.
    def index
      user_id = @env.get("user").as(App::Models::User).id.as(Int64)
      @env.response.content_type = "text/plain; version=0.0.4; charset=utf-8"
      @env.response.headers["Cache-Control"] = "no-store"

      String.build do |io|
        metric(io, "bit_links", "Number of stored short links for this user.")
        App::Lib::Database.raw_query("SELECT COUNT(*) FROM links WHERE user_id = ?", user_id) do |rows|
          rows.move_next
          io << "bit_links " << rows.read(Int64) << '\n'
        end

        metric(io, "bit_clicks", "Number of stored clicks for this user.")
        App::Lib::Database.raw_query("SELECT COUNT(*) FROM clicks c JOIN links l ON l.id = c.link_id WHERE l.user_id = ?", user_id) do |rows|
          rows.move_next
          io << "bit_clicks " << rows.read(Int64) << '\n'
        end

        metric(io, "bit_link_clicks", "Number of stored clicks by short link, including links without clicks.")
        App::Lib::Database.raw_query("SELECT l.slug, COUNT(c.id) FROM links l LEFT JOIN clicks c ON c.link_id = l.id WHERE l.user_id = ? GROUP BY l.id, l.slug ORDER BY l.slug", user_id) do |rows|
          rows.each do
            slug = rows.read(String)
            count = rows.read(Int64)
            io << "bit_link_clicks{slug=\"" << escape_label(slug) << "\"} " << count << '\n'
          end
        end

        # Separate dimensions avoid a series for every combination of labels.
        {"country", "browser", "os", "referer"}.each do |dimension|
          name = "bit_clicks_by_#{dimension}"
          metric(io, name, "Number of stored clicks by #{dimension} for this user.")
          App::Lib::Database.raw_query("SELECT COALESCE(c.#{dimension}, ''), COUNT(*) FROM clicks c JOIN links l ON l.id = c.link_id WHERE l.user_id = ? GROUP BY COALESCE(c.#{dimension}, '') ORDER BY 1", user_id) do |rows|
            rows.each do
              value = rows.read(String)
              count = rows.read(Int64)
              io << name << '{' << dimension << "=\"" << escape_label(value) << "\"} " << count << '\n'
            end
          end
        end
      end
    end

    private def metric(io : IO, name : String, help : String)
      io << "# HELP " << name << ' ' << help << '\n'
      io << "# TYPE " << name << " gauge\n"
    end

    private def escape_label(value : String) : String
      value.gsub('\\', "\\\\").gsub('"', "\\\"").gsub('\n', "\\n")
    end
  end
end
