$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# Pin TZ so Formatter's .localtime output is deterministic regardless of where
# tests run (developer laptops vs CI).
ENV["TZ"] = "Asia/Tokyo"

require "minitest/autorun"
require "webmock/minitest"
require "tempest"

WebMock.disable_net_connect!
