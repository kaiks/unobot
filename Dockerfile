# see https://github.com/evilmartians/fullstaq-ruby-docker
ARG RUBY_VERSION=3.4.4-jemalloc-bookworm

FROM quay.io/evl.ms/fullstaq-ruby:${RUBY_VERSION}-slim

ENV APP_HOME=/unobot
RUN mkdir $APP_HOME
WORKDIR $APP_HOME

# Copy over our application code
ADD . .
RUN gem install bundler -v 2.4.22
RUN bundle install

# Create logs directory for tests
RUN mkdir -p logs

CMD ruby uno_bot_starter.rb