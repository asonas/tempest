require_relative "../commands"
require_relative "../commands/base"
require_relative "../post"
require_relative "../post_view"
require_relative "../date_filter"
require_relative "../handle_lookup"
require_relative "../output/json_writer"
require_relative "../output/line_writer"

module Tempest
  module Commands
    module Feed
      DEFAULT_LIMIT = 50
      MAX_LIMIT = 100

      module_function

      def call(argv:, session:, client:, stdout:, stderr:)
        subcommand, rest = argv.first, argv.drop(1)
        unless %w[me timeline author].include?(subcommand)
          stderr.puts "usage: tempest feed me|timeline|author <handle> [opts]"
          return 64
        end

        opts, positional = parse(rest, stderr: stderr)
        return 64 if opts.nil?

        nsid, base_query = endpoint_for(subcommand, session: session, positional: positional, client: client)
        if nsid.nil?
          stderr.puts "error: feed author requires a handle or DID"
          return 64
        end
        if opts[:limit] > MAX_LIMIT
          stderr.puts "error: --limit must be <= #{MAX_LIMIT}"
          return 64
        end

        items = []
        cursor = nil
        max_pages = 5
        pages = 0
        loop do
          query = base_query.merge("limit" => opts[:limit])
          query["cursor"] = cursor if cursor
          response = client.get(nsid, query: query)
          page_items = Array(response["feed"]).map { |entry| entry["post"] }
          items.concat(page_items)
          pages += 1
          cursor = response["cursor"]
          break if cursor.nil? || cursor.empty?
          break if pages >= max_pages
          break unless opts[:since]
          oldest = page_items.last && page_items.last.dig("record", "createdAt")
          break if oldest.nil?
          break if Time.iso8601(oldest) < opts[:since]
        end
        stderr.puts "warning: pagination cap of #{max_pages} pages reached; result truncated" if pages >= max_pages && !cursor.nil? && !cursor.empty?

        items = filter_by_date(items, opts)
        emit(items, format: opts[:format], stdout: stdout)
        0
      end

      def parse(argv, stderr:)
        opts = { limit: DEFAULT_LIMIT, since: nil, until_at: nil, format: nil }
        positional = []
        i = 0
        while i < argv.length
          case argv[i]
          when /\A--limit=(\d+)\z/ then opts[:limit] = Regexp.last_match(1).to_i; i += 1
          when "--limit"           then opts[:limit] = argv[i + 1].to_i; i += 2
          when /\A--since=(.+)\z/  then opts[:since] = Tempest::DateFilter.parse(Regexp.last_match(1)); i += 1
          when "--since"           then opts[:since] = Tempest::DateFilter.parse(argv[i + 1]); i += 2
          when /\A--until=(.+)\z/  then opts[:until_at] = Tempest::DateFilter.parse(Regexp.last_match(1)); i += 1
          when "--until"           then opts[:until_at] = Tempest::DateFilter.parse(argv[i + 1]); i += 2
          when /\A--format=(\S+)\z/
            sym = Regexp.last_match(1).to_sym
            unless %i[line json raw].include?(sym)
              stderr.puts "error: invalid --format: #{Regexp.last_match(1).inspect}"
              return [nil, nil]
            end
            opts[:format] = sym
            i += 1
          when "--no-color"
            Tempest::REPL::Formatter.color = false if defined?(Tempest::REPL::Formatter)
            i += 1
          else
            positional << argv[i]; i += 1
          end
        end
        [opts, positional]
      rescue ArgumentError => e
        stderr.puts "error: #{e.message}"
        [nil, nil]
      end

      def endpoint_for(subcommand, session:, positional:, client:)
        case subcommand
        when "me"
          ["app.bsky.feed.getAuthorFeed", { "actor" => session.did }]
        when "timeline"
          ["app.bsky.feed.getTimeline", {}]
        when "author"
          actor = positional.first
          if actor.nil? || actor.empty?
            return [nil, nil]
          end
          did = Tempest::HandleLookup.resolve(actor, client: client)
          ["app.bsky.feed.getAuthorFeed", { "actor" => did }]
        end
      end

      def filter_by_date(items, opts)
        return items if opts[:since].nil? && opts[:until_at].nil?
        items.select do |it|
          ts = it.dig("record", "createdAt")
          t = Time.iso8601(ts)
          (opts[:since].nil? || t >= opts[:since]) && (opts[:until_at].nil? || t < opts[:until_at])
        end
      end

      def emit(items, format:, stdout:)
        format ||= stdout.respond_to?(:tty?) && stdout.tty? ? :line : :json
        case format
        when :json
          views = items.map { |i| Tempest::PostView.from_feed_view(i) }
          Tempest::Output::JsonWriter.new(stdout).write_posts(views)
        when :line
          posts = items.map { |i| Tempest::Post.from_feed_view(i) }
          Tempest::Output::LineWriter.new(stdout).write_posts(posts)
        when :raw
          Tempest::Output::JsonWriter.new(stdout).write_raw({ "feed" => items.map { |i| { "post" => i } } })
        end
      end
    end
  end
end
