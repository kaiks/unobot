# see https://github.com/evilmartians/fullstaq-ruby-docker
ARG RUBY_VERSION=2.6.9-jemalloc-bullseye

FROM quay.io/evl.ms/fullstaq-ruby:${RUBY_VERSION}-slim

ENV APP_HOME /unobot
RUN mkdir $APP_HOME
WORKDIR $APP_HOME

# Copy over our application code
ADD . .
RUN gem install cinch
CMD ruby uno_bot_starter.rb