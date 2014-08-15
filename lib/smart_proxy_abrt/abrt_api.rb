require 'openssl'
require 'json'

require 'smart_proxy_abrt/abrt_lib'

STATUS_ACCEPTED = 202

module Proxy::Abrt
  class Api < ::Sinatra::Base
    include ::Proxy::Log
    helpers ::Proxy::Helpers

    post '/reports/new/' do
      begin
        cn = Proxy::Abrt::common_name request
      rescue Proxy::Error::Unauthorized => e
        log_halt 403, "Client authentication failed: #{e.message}"
      end

      ureport_json = request['file'][:tempfile].read
      ureport = JSON.parse(ureport_json)

      #forward to FAF
      response = nil
      if Proxy::Abrt::Plugin.settings.server_url
        begin
          result = Proxy::Abrt::faf_request "/reports/new/", ureport_json
          response = result.body if result.code.to_s == STATUS_ACCEPTED.to_s
        rescue StandardError => e
          logger.error "Unable to forward to ABRT server: #{e}"
        end
      end
      unless response
        # forwarding is not configured or failed
        # FAF source that generates replies is in src/webfaf/reports/views.py
        response = { "result" => false,
                     "message" => "Report queued" }
        if Proxy::SETTINGS.foreman_url
          foreman_url = Proxy::SETTINGS.foreman_url
          foreman_url += "/" if url[-1] != "/"
          foreman_url += "hosts/#{cn}/abrt_reports"
          response["reported_to"] = [{ "reporter" => "Foreman",
                                       "type" => "url",
                                       "value" => foreman_url }]
        end
        response = response.to_json
      end

      #save report to disk
      begin
        Proxy::Abrt::HostReport.save cn, ureport
      rescue StandardError => e
        log_halt 500, "Failed to save the report: #{e}"
      end

      status STATUS_ACCEPTED
      response
    end

    post '/reports/:action/' do
      # pass through to real FAF if configured
      if Proxy::Abrt::Plugin.settings.server_url
        body = request['file'][:tempfile].read
        begin
          result = Proxy::Abrt::faf_request "/reports/#{params[:action]}/", body
        rescue StandardError => e
          log_halt 503, "ABRT server unavailable: #{e}"
        end
        status result.code
        result.body
      else
        log_halt 501, "foreman-proxy does not implement /reports/#{params[:action]}/"
      end
    end
  end
end