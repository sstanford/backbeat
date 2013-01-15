require 'spec_helper'

describe Api::Workflow do
  include Rack::Test::Methods

  def app
    FullRackApp
  end

  before do
    header 'CLIENT_ID', RSPEC_CONSTANT_USER_CLIENT_ID
    WorkflowServer::AsyncClient.stub(:make_decision)
  end

  context "GET /events/id" do
    it "returns an event object with valid params" do
      decision = FactoryGirl.create(:decision)
      get "/events/#{decision.id}"
      last_response.status.should == 200
      json_response = JSON.parse(last_response.body)
      json_response['_id'].should == decision.id.to_s
    end

    it "returns a 404 if the event is not found" do
      wf = FactoryGirl.create(:workflow)
      get "/events/1000"
      last_response.status.should == 404
      json_response = JSON.parse(last_response.body)
      json_response.should == {"error" => "Event with id(1000) not found"}
    end

    it "returns a 404 if a user tries to access a workflow that doesn't belong to them" do
      decision = FactoryGirl.create(:decision)
      user = FactoryGirl.create(:user, id: UUID.generate)
      header 'CLIENT_ID', user.id
      get "/events/#{decision.id}"
      last_response.status.should == 404
      json_response = JSON.parse(last_response.body)
      json_response.should == {"error" => "Event with id(#{decision.id}) not found"}
    end
  end
end