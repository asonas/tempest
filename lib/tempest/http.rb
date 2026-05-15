require "net/http"
require "json"
require "uri"

require_relative "../tempest"

module Tempest
  # Thin JSON-over-HTTP transport for XRPC endpoints.
  # Deliberately uses Net::HTTP at this stage. We may swap to a persistent
  # HTTP layer later (see plan.md), but the interface here is the seam.
  module HTTP
    module_function

    def post_json(url, body:, headers: {})
      request(Net::HTTP::Post, url, body: body, headers: headers)
    end

    def get_json(url, headers: {}, query: nil)
      uri = URI(url)
      if query && !query.empty?
        existing = URI.decode_www_form(uri.query || "")
        uri.query = URI.encode_www_form(existing + query.to_a)
      end
      request(Net::HTTP::Get, uri.to_s, headers: headers)
    end

    def request(klass, url, body: nil, headers: {})
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"

      req = klass.new(uri.request_uri)
      headers.each { |k, v| req[k] = v }
      if body
        req["Content-Type"] ||= "application/json"
        req.body = JSON.generate(body)
      end

      response = http.request(req)
      Response.new(response.code.to_i, parse_body(response))
    end

    def parse_body(response)
      content_type = response["Content-Type"].to_s
      return nil if response.body.nil? || response.body.empty?
      return JSON.parse(response.body) if content_type.include?("application/json")
      response.body
    end

    Response = Struct.new(:status, :body) do
      def ok?
        status >= 200 && status < 300
      end

      def unauthorized?
        status == 401
      end
    end
  end
end
