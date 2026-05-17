require_relative "../id_var"

module Tempest
  module REPL
    # Holds two IdVar rings (post + link) plus side tables that resolve a
    # var string back to the original Post / URL. Lifetime is the
    # current REPL session; nothing is persisted.
    class Registry
      def initialize
        @post_ids = Tempest::IdVar.new(range: "AA".."ZZ")
        @link_ids = Tempest::IdVar.new(range: "LA".."LZ")
        @posts = {}
        @urls = {}
      end

      def assign_post(post)
        var = @post_ids.generate(post_key(post))
        @posts[var] = post
        var
      end

      def assign_url(url)
        var = @link_ids.generate(url)
        @urls[var] = url
        var
      end

      def find_post(var)
        @posts[var]
      end

      def find_url(var)
        @urls[var]
      end

      # Reverse lookup: returns the var currently mapped to the given
      # post URI, or nil if the URI has never been assigned or its slot
      # has been recycled to a different post.
      def var_for_uri(uri)
        @posts.each do |var, post|
          return var if post_key(post) == uri
        end
        nil
      end

      private

      def post_key(post)
        if post.respond_to?(:uri) && post.uri
          post.uri
        else
          post.at_uri
        end
      end
    end
  end
end
