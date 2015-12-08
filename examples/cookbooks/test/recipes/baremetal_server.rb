# This is a sample recipe
#
# Note: It layouts the sample recipe to show how to use SoftLayer
#       driver of Chef Provisioning to provision bare metal server
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

require 'openssl'
OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE

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
                            :instance_type => "bare_metal_server"   # One of "virtual_server", 
                                                                    #  "bare_metal_instance"
                                                                    # or "bare_metal_server"
                         }
machine_options = {
  :billing_period => "monthly",            # Billing period
                                           # Required, String, "hourly"(default)
                                           # One of "hourly" or "monthly" if "virtual_server" or "bare_metal_instance"
                                           # ONLY "monthly" if "bare_metal_server"

  :datacenter =>  "wdc01",                 # Pre-defined names of data centers by SoftLayer API
                                           # Required, String, "wdc01"(default)
                                           # "wdc01" or "Washington DC, 1"
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
    :cores => 8,                          # Number of cores
                                          # Required, Integer
    :type  => "Dual Intel Xeon E5-2650 "  # full description of cpu type as SoftLayer Portal display while ordering in Web
  },

  :ram =>  16,                             # Amount of RAM in GB
                                           # Required, Integer

  :os_name =>  "Red Hat Enterprise Linux 6.x (64 bit) (per-processor licensing)",
                                           # full description of OS name as SoftLayer Portal describe while ordering
                                           # Required, String

  :network => {                            # Network configuration
                                           # Required, Object
      :hostname    => "sl-driver-test",    # provide a host name
      :domain      => "imdemocloud.com",   # provide a domain name                               
      :description => "1 Gbps Public & Private Network Uplinks"
                                           # Use text description for bare metal server to identify network spec, like:
                                           # "100 Mbps Public & Private Network Uplinks"
                                           # "100 Mbps Redundant Private Network Uplinks"
                                           # "1 Gbps Private Network Uplink"
                                           # "1 Gbps Public & Private Network Uplinks"
                                           # "1 Gbps Public & Private Network Uplinks (Unbonded)"
                                           # "1 Gbps Dual Public & Private Network Uplinks (Unbonded)""
                                           # "10 Gbps Redundant Private Network Uplinks"
                                           # "10 Gbps Public & Private Network Uplinks (Non Datacenter Restricted)"
  },

  :storage => {                           # storage configuration
      :server_disks_max => 4,             # available storage units("Up to drives")
                                          # Required if "bare_metal_server"
      :server_disks => [                  # disks configuration
                                          # Required, Array
             {
               :seq_id => 0,                     # disk index tag for storage group
               :description => "1.00 TB SATA"   # full description of disk as SoftLayer Portal describe while ordering
             },
             {
               :seq_id => 1,
               :description => "1.00 TB SATA"
             },
             {
               :seq_id => 2,
               :description => "1.00 TB SATA" 
             }
         ],
      :storage_groups => [                        # RAID configuration
                                                 # Required if bare metal server
             { :type   => "RAID 1", :hard_drives => [0,1] },
             { :type   => "JBOD",   :hard_drives => [2] }
      ]
  },

# :key_name                                # name for key pair created via softlayer_ssh_key
                                           # provider and resource

# :provision_timeout => 3600,              # time out for server provision in seconds
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

  # :template_id   =>                      # SoftLayer Flex image ID (aka. GlobaleIdentifier) to provision from
                                           # Optional, String 

  # :notes        =>                       # Addtional note for an instance
                                           # Optional, String
}

with_machine_options machine_options

# singel machine provision
machine "baremetal-server-node" do
  tag "baremetal-server-node"
  # action :destroy
  # recipe "myapp::recipe1"
  # role   "role"
end


# batch machines provision
#machine_batch do
#  # action :destroy
#  1.upto(2) do |i|
#    machine "sample-node-#{i}" do
#      tag "sample-node-#{i}"
#      # recipe "myapp::recipe1"
#      # role   "role"
#    end
#  end
#end

