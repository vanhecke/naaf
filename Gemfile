source "https://rubygems.org"

ruby file: ".ruby-version"

gem "falcon"          # web server (async reactor)
gem "roda"            # routing
gem "async-dns"       # DNS server — modern successor to rubydns
gem "sequel"          # DB toolkit
gem "sqlite3"         # driver
gem "rack-session"    # admin session cookie
gem "bcrypt"          # admin password hash
gem "rqrcode"         # client config QR (inline SVG)
gem "console"         # socketry structured logging
gem "tilt"            # template interface Roda's :render plugin requires
gem "erubi"           # ERB engine tilt delegates to for .erb templates

# Ruby 4.0 moved these from default to bundled gems. Declare them so transitive
# deps don't fail with `cannot load such file`. Prune any that prove unused.
gem "logger"
gem "ostruct"
gem "benchmark"
gem "cgi"

group :development, :test do
  gem "standard", require: false
  gem "sus"
  gem "sus-fixtures-async"
end
