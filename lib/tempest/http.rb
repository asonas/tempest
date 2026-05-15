require "json"
require "uri"
require "async"
require "async/http/internet"

require_relative "../tempest"

module Tempest
  # JSON-over-HTTP transport for XRPC endpoints.
  # Backed by Async::HTTP::Internet, which keeps connections alive per origin
  # and reuses them across calls. The public interface stays synchronous
  # (returns Response on call) by wrapping work in Sync so the REPL doesn't
  # need to know about Async.
  module HTTP
    Response = Struct.new(:status, :body) do
      def ok?
        status >= 200 && status < 300
      end

      def unauthorized?
        status == 401
      end
    end

    @internet_mutex = Mutex.new
    @internet = nil

    module_function

    def post_json(url, body: nil, headers: {})
      request("POST", url, body: body, headers: headers)
    end

    def get_json(url, headers: {}, query: nil)
      uri = URI(url)
      if query && !query.empty?
        existing = uri.query ? URI.decode_www_form(uri.query) : []
        uri.query = URI.encode_www_form(existing + query.to_a)
      end
      request("GET", uri.to_s, headers: headers)
    end

    def request(method, url, body: nil, headers: {})
      normalized = headers.each_with_object({}) { |(k, v), h| h[k.to_s.downcase] = v }
      payload = nil
      if body
        normalized["content-type"] ||= "application/json"
        payload = [JSON.generate(body)]
      end
      normalized["accept"] ||= "application/json"

      header_pairs = normalized.to_a

      Sync do
        response = internet.call(method, url, header_pairs, payload)
        begin
          body_str = response.read.to_s
          Response.new(response.status, parse_body(response, body_str))
        ensure
          response.close
        end
      end
    end

    def parse_body(response, body_str)
      return nil if body_str.empty?
      ctype = response.headers["content-type"].to_s
      return JSON.parse(body_str) if ctype.include?("application/json")
      body_str
    end

    def internet
      @internet_mutex.synchronize do
        @internet ||= Async::HTTP::Internet.new
      end
    end

    def reset!
      @internet_mutex.synchronize do
        existing = @internet
        @internet = nil
        if existing
          Sync { existing.close }
        end
      end
    end
  end
end
