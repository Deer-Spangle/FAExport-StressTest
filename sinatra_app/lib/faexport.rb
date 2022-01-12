# frozen_string_literal: true

# faexport.rb - Simple data export and feeds from FA
#
# Copyright (C) 2015 Erra Boothale <erra@boothale.net>
# Further work: 2020 Deer Spangle <deer@spangle.org.uk>
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
#   * Redistributions of source code must retain the above copyright notice,
#     this list of conditions and the following disclaimer.
#   * Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
#   * Neither the name of FAExport nor the names of its contributors may be
#     used to endorse or promote products derived from this software without
#     specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

$: << File.dirname(__FILE__)

require "active_support"
require "active_support/core_ext"
require "builder"
require "faexport/scraper"
require "redcarpet"
require "sinatra/base"
require "sinatra/json"
require "yaml"
require "tilt"

Tilt.register Tilt::RedcarpetTemplate, "markdown", "md"

# Do not update this manually, the github workflow does it.
VERSION = "2022.01.1"


module FAExport
  class << self
    attr_accessor :config
  end

  class Application < Sinatra::Base
    log_directory = ENV["LOG_DIR"] || "logs/"
    FileUtils.mkdir_p(log_directory)
    access_log = File.new("#{log_directory}/access.log", "a+")
    access_log.sync = true
    error_log = File.new("#{log_directory}/error.log", "a+")
    error_log.sync = true

    configure do
      enable :logging
      use Rack::CommonLogger, access_log
    end

    set :public_folder, File.join(File.dirname(__FILE__), "faexport", "public")
    set :views, File.join(File.dirname(__FILE__), "faexport", "views")
    set :markdown, with_toc_data: true, fenced_code_blocks: true

    USER_REGEX = /((?:[a-zA-Z0-9\-_~.]|%5B|%5D|%60)+)/
    ID_REGEX = /([0-9]+)/
    COOKIE_REGEX = /^([ab])=[a-z0-9\-]+; ?(?!\1)[ab]=[a-z0-9\-]+$/
    NOTE_FOLDER_REGEX = /(inbox|outbox|unread|archive|trash|high|medium|low)/

    def initialize(app, config = {})
      FAExport.config = config.with_indifferent_access
      FAExport.config[:cache_time] ||= 30 # 30 seconds
      FAExport.config[:cache_time_long] ||= 86_400 # 1 day
      FAExport.config[:redis_url] ||= (ENV["REDIS_URL"] || ENV["REDISTOGO_URL"])
      FAExport.config[:username] ||= ENV["FA_USERNAME"]
      FAExport.config[:password] ||= ENV["FA_PASSWORD"]
      FAExport.config[:cookie] ||= ENV["FA_COOKIE"]
      FAExport.config[:rss_limit] ||= 10
      FAExport.config[:content_types] ||= {
        "json" => "application/json",
        "xml" => "application/xml",
        "rss" => "application/rss+xml"
      }

      @cache = RedisCache.new(FAExport.config[:redis_url],
                              FAExport.config[:cache_time],
                              FAExport.config[:cache_time_long])
      @fa = Furaffinity.new(@cache)
      @some_obj = {
        user_cookie: nil
      }

      @system_cookie = FAExport.config[:cookie] || @cache.redis.get("login_cookie")
      unless @system_cookie
        @system_cookie = @fa.login(FAExport.config[:username], FAExport.config[:password])
        @cache.redis.set("login_cookie", @system_cookie)
      end

      super(app)
    end

    helpers do
      def cache(key, &block)
        # Cache rss feeds for one hour
        long_cache = key =~ /\.rss$/
        @cache.add("#{key}.#{@fa.safe_for_work}", long_cache, &block)
      end

      def set_content_type(type)
        content_type FAExport.config[:content_types][type], "charset" => "utf-8"
      end

      def ensure_login!
        return if @user_cookie

        raise FALoginCookieError.new(
          'You must provide a valid login cookie in the header "FA_COOKIE".'\
          "Please note this is a header, not a cookie."
        )
      end
    end

    before do
      env["rack.errors"] = error_log
      @user_cookie = request.env["HTTP_FA_COOKIE"]
      @some_obj[:user_cookie] = @user_cookie
      # @fa = Furaffinity.new(@cache)  # TODO: testing
      if @user_cookie
        if @user_cookie =~ COOKIE_REGEX
          @fa.login_cookie = @user_cookie.strip
        else
          raise FALoginCookieError.new(
            "The login cookie provided must be in the format"\
            '"b=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx; a=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"'
          )
        end
      else
        @fa.login_cookie = @system_cookie
      end

      @fa.safe_for_work = !!params[:sfw]
    end

    after do
      @fa.login_cookie = nil
      @fa.safe_for_work = false
      @user_cookie = nil
      @some_obj[:user_cookie] = nil
    end

    get "/" do
      JSON.pretty_generate({test: "hello world"})
    end

    # GET /notifications/others.json
    # GET /notifications/others.xml
    get %r{/notifications/others\.(json|xml)} do |type|
      ensure_login!
      include_deleted = !!params[:include_deleted]
      set_content_type(type)
      # Removing cache makes the bug less likely, but still there.
      cache("notifications:#{@user_cookie}:#{include_deleted}.#{type}") do
        case type
        when "json"
          # JSON.pretty_generate @fa.notifications(include_deleted)
          # TODO: Oh, if I swap for the next line, the error goes away
          # JSON.pretty_generate({current_user: {"name": @user_cookie}})
          JSON.pretty_generate({current_user: {"name": @some_obj[:user_cookie]}})
        when "xml"
          @fa.notifications(include_deleted).to_xml(root: "results", skip_types: true)
        else
          raise Sinatra::NotFound
        end
      end
    end

    error FAError do
      err = env["sinatra.error"]
      status(
        case err
        when FASearchError      then 400
        when FALoginCookieError then 400
        when FAFormError        then 400
        when FAOffsetError      then 400
        when FALoginError       then @user_cookie ? 401 : 503
        when FASystemError      then 404
        when FAStatusError      then 502
        when FACloudflareError  then 503
        else 500
        end
      )

      JSON.pretty_generate error: err.message, url: err.url
    end

    error do
      status 500
      "FAExport encounter an internal error"
    end
  end
end
