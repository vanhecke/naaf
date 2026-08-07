# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("lib", __dir__))
require "wgcp/app"
run WGCP::App.freeze.app
