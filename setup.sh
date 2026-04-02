#!/bin/bash
set -e

echo "=== Mail Service — cPanel Setup ==="

# 1. Check Ruby
if ! command -v ruby &> /dev/null; then
    echo "ERROR: Ruby not found."
    echo "Install Ruby via cPanel → Setup Ruby App, or via rbenv:"
    echo "  git clone https://github.com/rbenv/rbenv.git ~/.rbenv"
    echo "  git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build"
    echo "  echo 'export PATH=\"\$HOME/.rbenv/bin:\$PATH\"' >> ~/.bashrc"
    echo "  echo 'eval \"\$(rbenv init -)\"' >> ~/.bashrc"
    echo "  source ~/.bashrc"
    echo "  rbenv install 3.2.3 && rbenv global 3.2.3"
    exit 1
fi
echo "✓ Ruby $(ruby -v | awk '{print $2}')"

# 2. Check Bundler
if ! command -v bundle &> /dev/null; then
    echo "Installing Bundler..."
    gem install bundler --no-document
fi
echo "✓ Bundler $(bundle -v | awk '{print $3}')"

# 3. Install dependencies
echo ""
echo "Installing gems..."
bundle config set --local path 'vendor/bundle'
bundle config set --local without 'development test'
bundle install --jobs 4
echo "✓ Gems installed"

# 4. Setup .env
if [ ! -f .env ]; then
    cp .env.example .env
    echo ""
    echo "⚠  .env file created from .env.example"
    echo "   Please edit .env and set your values:"
    echo "   - DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASS"
    echo "   - ENCRYPTION_KEY (run: ruby -e \"require 'securerandom'; puts SecureRandom.hex(32)\")"
    echo "   - MASTER_API_KEY (run: ruby -e \"require 'securerandom'; puts SecureRandom.hex(32)\")"
    echo ""
    echo "After editing .env, restart the app via cPanel or run:"
    echo "  touch tmp/restart.txt"
else
    echo "✓ .env already exists"
fi

# 5. Create tmp/ for Passenger restart
mkdir -p tmp
echo "✓ tmp/ directory ready"

# 6. Update .htaccess with actual Ruby path
RUBY_PATH=$(which ruby)
if [ -f .htaccess ]; then
    sed -i "s|PassengerRuby .*|PassengerRuby $RUBY_PATH|" .htaccess
    APP_ROOT=$(pwd)
    sed -i "s|PassengerAppRoot .*|PassengerAppRoot $APP_ROOT|" .htaccess
    echo "✓ .htaccess updated (Ruby: $RUBY_PATH)"
fi

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit .env with your database and key settings"
echo "  2. Restart app: touch tmp/restart.txt"
echo "  3. Database tables will be created automatically on first request"
echo ""
