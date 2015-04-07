require 'chef/provisioning'

class Chef::Resource::SoftlayerSshKey < Chef::Resource::LWRPBase
  self.resource_name = 'softlayer_ssh_key'

  def initialize(*args)
    super
    @driver = run_context.chef_provisioning.current_driver
  end

  actions :create
  default_action :create

  attribute  :softlayer_username, :kind_of => String
  attribute  :softlayer_api_key,  :kind_of => String

end