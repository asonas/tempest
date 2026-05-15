require_relative "tempest/version"

module Tempest
  class Error < StandardError; end
  class AuthenticationError < Error; end
  class APIError < Error
    attr_reader :status, :body

    def initialize(status, body)
      @status = status
      @body = body
      super("XRPC request failed with status #{status}: #{body.inspect}")
    end
  end
end
