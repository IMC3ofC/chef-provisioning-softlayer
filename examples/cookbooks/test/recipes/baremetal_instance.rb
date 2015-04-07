# This is a sample recipe for SoftLayer provisioner
#
# Note: It layouts the sample recipe to show how to invoke SoftLayer
#       driver in Chef Provisioning for bare metal instance
#
#
# Authors:
#   * Zhongyu (Leo) Wu           <leow@ca.ibm.com>
#   * Emerging Technologies Team <imcloud@ca.ibm.com>
#     IBM Analytics Platform
#
# Copyright 2015, IBM Corporation
# All rights reserved
#


require 'chef'
require 'chef/provisioning'
require 'chef/provisioning/softlayer_driver/driver'

# Please fill in your username/api_key of SoftLayer to run
user_name = nil
api_key   = nil

user_name ||= ENV["API_USERNAME"]
api_key   ||= ENV["API_KEY"]

# Initialize SoftLayer driver
with_driver 'softlayer', {  :user_name => user_name,
                            :api_key   => api_key,
                            :instance_type => "bare_metal_instance"   # instance type on SoftLayer
                                                                      # Required, String
                                                                      # One of "virtual_server", "bare_metal_instance"
                                                                      # or "bare_metal_server"
                          }

# Sample provisioner options for SoftLayer
machine_options  = {
  :billing_period =>  "hourly",            # Billing period
                                           # Required, String, "hourly"(default)
                                           # One of "hourly" or "monthly" if "virtual_server" or "bare_metal_instance"
                                           # ONLY "monthly" if "bare_metal_server"

  :datacenter  =>  "wdc01",                # Pre-defined names of data centers by SoftLayer API
                                           # Required, String, "wdc01"(default)
                                           # "wdc01", Washington DC, 1
                                           # "ams01", Amsterdam 1
                                           # "dal01", Dallas 1
                                           # "dal02", Dallas 2
                                           # "dal04", Dallas 4
                                           # "dal05", Dallas 5
                                           # "dal06", Dallas 6
                                           # "hkg02", Hong Kong 2
                                           # "lon02", London 2
                                           # "sjc01", San Jose 1
                                           # "sea01", Seattle
                                           # "sng01", Singapore 1
                                           # "tor01", Toronto 1
                                           # "mel01", melbourne 1
                                           # "par01", Paris 1
                                           # "fra02", Frankfurt 2
                                           # "mex01", Mexico 1
  :cpu => {
    :cores => 2                            # Number of cores
                                           # Required, Integer
  },

  :ram =>  2,                              # Amount of RAM in GB
                                           # Required, Integer

  :os_name => "FreeBSD 8.x (32 bit)",      # full description of OS name as SoftLayer Portal describe while ordering
                                           # Required, String
                                           # Note: only particular OS available for hourly for bare metal instance
                                           #       contact IBM SoftLayer support for detail information

  :network => {                            # Network configuration
                                           # Required, Object
      :hostname => "sample-node-test",     # provide a host name
                                           # Required, String
      :domain   => "imdemocloud.com",      # provide a domain name
                                           # Required, String                               
      :speed    =>  1000                   # Speed of network in Mbps
                                           # Optional, Integer, 1000 (default)
                                           # One of 10, 100, 1000 if "virtual server" or "bare meteal instance"
                                           # One of 100, 1000, 100000 if "bare meteal server"
  },

  :storage  => {                           # storage configuration for "bare metal instance"
   :server_disks => [                      # disks 
                                           # Required, Object
       {  
         :seq_id   => "0",                 # disk index
                                           # one disk ONLY if bare metal instance
         :capacity =>  500,                # disk size in GB
                                           # ONLY 500 if "bare metal instance"
         :type     => "SATA II"            # disk type
                                           # ONLY "SATA II" if "bare metal instance"
       }
    ]
  },

# :key_name                                # name for key pair created via softlayer_ssh_key
                                           # provider and resource

# :provision_timeout  => 3600,             # time out for server provision in seconds
                                           # Optional, Integer
                                           # 3600  if "virtual server" 
                                           # 7200  if "bare metal instance"
                                           # 86400 if "bare metal server"

# :convergence_options => {                # convergence options defined in chef provisioning
#   :chef_version  =>                      # a customized chef client version
                                           # Optional, String
                                           # i.e. "11.14.0"

#   :ssl_verify_mode =>                    # ssl verify mode setting
                                           # optional, "verify_none" or "verify_peer"
# }

# :template_id   =>                        # SoftLayer Flex image ID (aka. GlobaleIdentifier) to provision from
                                           # Optional, String 
                                           # i.e. "7dfe506c-e0e6-43b0-b082-96863a3926c0",

# :notes         =>                        # Addtional note for an instance
                                           # Optiona, String
 
}

# Set up options for instance provisioning on SoftLayer
with_machine_options machine_options


# singel machine resource provision
machine "baremetal-instance-node" do
  tag "baremetal-instance-node"
  # action :destroy
  # recipe "myapp::recipe1"
  # role   "role"
end


# batch machine resource provision
#machine_batch do
#  # action :destroy
#  1.upto(2) do |i|
#    machine "biginsight-master-node-#{i}" do
#      tag "biginsight-master-node-#{i}"
#      # recipe "myapp::recipe1"
#      # role   "role"
#    end
#  end
#end
