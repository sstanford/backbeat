require 'spec_helper'

describe Api::SidekiqLatency do
  include Rack::Test::Methods

  def app
    FullRackApp
  end

  context "/sidekiq_latency" do
    it "catches the request, returns 200 and the queue latency" do
      response = get '/sidekiq_latency'
      response.status.should == 200
      response.body.should == "0"
    end
  end
end
