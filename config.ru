# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("lib", __dir__))
require "naaf/app"
run Naaf::App.freeze.app
