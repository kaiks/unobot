ARG RUBY_IMAGE=docker.io/library/ruby@sha256:654c8382a37d73dc8cb7dfe784d711ea82be6aafae2c8fee939149fd80a507c1
FROM ${RUBY_IMAGE}

# Install git for fetching gems from GitHub
RUN apt-get update -q && \
    apt-get install -y --no-install-recommends git && \
    rm -rf /var/lib/apt/lists/*

ENV APP_HOME=/unobot
RUN mkdir $APP_HOME
WORKDIR $APP_HOME

# Copy over our application code
ADD . .
RUN gem install bundler -v 4.0.16
RUN bundle config set without development && bundle install

# Create logs directory for tests
RUN mkdir -p logs

CMD ruby uno_bot_starter.rb
