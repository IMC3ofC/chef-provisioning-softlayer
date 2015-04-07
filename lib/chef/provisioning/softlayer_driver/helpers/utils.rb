#
# Chef Provisioning driver for SoftLayer
#
# Functions: helper functions and constants
#
# Authors:
#   * Zhongyu (Leo) Wu           <leow@ca.ibm.com>
#   * Emerging Technologies Team <imcloud@ca.ibm.com>
#     IBM Analytics Platform
#
# Copyright 2015, IBM Corporation
# All rights reserved
#

class Chef
module Provisioning
    # a provisioner dedicated for IBM SoftLayer
    class SoftlayerDriver < Chef::Provisioning::Driver
      
      private

      DEFAULT_OPTIONS = {
        :provision_timeout => {
          :virtual_server      =>   3600,
          :bare_metal_instance =>   7200,
          :bare_metal_server   =>  86400
        },
        :ssh_timeout           =>    120,
        :bandwidth             =>    "20000 GB Bandwidth",
        :network_speed         =>    "1000"
      }

      INSTANCE_IDX = ["virtual_server", "bare_metal_instance", "bare_metal_server"]
      INSTANCE_TYPES = {
        # virtual server packge id and name
        virtual_server:        { id: 46,  name: INSTANCE_IDX[0] },
        # bare metal instance package id and name
        bare_metal_instance:   { id: 50,  name: INSTANCE_IDX[1] },
        # bare metal cpu for all bare metal server packages
        bare_metal_server:     { id: 2,   name: INSTANCE_IDX[2] }
      }
      
      SERVER_STATE = {
        RUNNING:  "RUNNING",
        PASUED:   "PAUSED",
        HATLED:   "HALTED",
        ON:       "ON"
      }

      PROVISION_STATE = { 
        INIT:  "INIT",
        DONE:  "DONE" 
      }


      BILLING_TYPE = {
        hourly:   "hourly",
        monthly:  "monthly"
      }

      # categories defined in SoftLayer API
      CATEGORY_ID = {
        bms_cpu:            1,
        bms_raid:          11,
        os:                12,
        ram:                3,
        cpu:               80,
        power_supply:      35,
        bandwidth:         10,
        network:           26,
        remote:            46,
        primary_ip:        13,
        monitoring:        20,
        response:          22,
        notification:      21,
        vpn:               31,
        vulnerability:     32,
        disks:  [
                  "81",    # "First Hard Drive",
                  "82",    # "Second Hard Drive",
                  "92",    # "Third Hard Drive",
                  "93",    # "Fourth Hard Drive",
                  "116"    # "Fifth Hard Drive",
                ],
        bms_disks: [
                     "4",    # "First Hard Drive",
                     "5",    # "Second Hard Drive",
                     "6",    # "Third Hard Drive",
                     "7",    # "Fourth Hard Drive",
                     "36",   # "Fifth Hard Drive",
                     "37",   # "Sixth Hard Drive",
                     "38",   # "Seventh Hard Drive",
                     "39",   # "Eighth Hard Drive",
                     "40",   # "Ninth Hard Drive",
                     "41",   # "Tenth Hard Drive",
                     "42",   # "Eleventh Hard Drive",
                     "43",   # "Twelfth Hard Drive",
                     "98",   # "Thirteenth Hard Drive",
                     "99",   # "Fourteenth Hard Drive",
                     "100",  # "Fifteenth  Hard Drive",
                     "101",  # "Sixteenth  Hard Drive",
                     "102",  # "Seventeenth  Hard Drive",
                     "103",  # "Eighteenth  Hard Drive",
                     "104",  # "Nineteenth  Hard Drive",
                     "105",  # "Twentieth  Hard Drive",
                     "106",  # "Twenty-first Hard Drive",
                     "107",  # "Twenty-second Hard Drive",
                     "108",  # "Twenty-third Hard Drive",
                     "109",  # "Twenty-fourth Hard Drive",
                     "126",  # "Twenty-fifth Hard Drive",
                     "127",  # "Twenty-sixth Hard Drive",
                     "128",  # "Twenty-seventh Hard Drive",
                     "129",  # "Twenty-eighth Hard Drive",
                     "130",  # "Twenty-nineth Hard Drive",
                     "131",  # "Thirtieth  Hard Drive",
                     "132",  # "Thirty-first Hard Drive",
                     "133",  # "Thirty-second Hard Drive",
                     "134",  # "Thirty-third Hard Drive",
                     "135",  # "Thirty-fourth Hard Drive",
                     "136",  # "Thirty-fifth Hard Drive",
                     "137"   # "Thirty-sixth Hard Drive"
                    ],
        disks_max:  1000     # driver defined category
      }

      # disk attributes defined in SoftLayer API
      DISK_ATTR_TYPE_ID = {
        "RAID 0"  => 1,
        "RAID 1"  => 2,
        "RAID 5"  => 3,
        "RAID 6"  => 4,
        "RAID 10" => 5,
        "JBOD"    => 9
      }

      # cancellation reasons defined in SoftLayer API
      CANCELLATION_REASONS = {
       "unneeded"         => "No longer needed",
       "closing"          => "Business closing down",
       "cost"             => "Server / Upgrade Costs",
       "migrate_larger"   => "Migrating to larger server",
       "migrate_smaller"  => "Migrating to smaller server",
       "datacenter"       => "Migrating to a different SoftLayer datacenter",
       "performance"      => "Network performance / latency",
       "support"          => "Support response / timing",
       "sales"            => "Sales process / upgrades",
       "moving"           => "Moving to competitor"
      }
      
      def wait_until_ready(machine_spec)
          transport = nil
          count     = DEFAULT_OPTIONS[:ssh_timeout] / 60

          count.times do
            server = server_for machine_spec
            if server[:power].upcase == SERVER_STATE[:running] ||
               server[:power].upcase == SERVER_STATE[:on]
              transport = transport_for machine_spec
              return true if transport && transport.available?
            end
            sleep 60
          end

          false
      end

      # Clean up the node's IP address from the known hosts file (~/.known_hosts)
      def cleanup_host(machine_spec)
        if machine_spec.location["ip_address"]
          %x(ssh-keygen -R "#{machine_spec.location["ip_address"]}")
        end
      end

      # construct supplemental specs
      # Note: mandotry system configuration for IBM SoftLayer 
      def supplemental_specs()
        supp_specs = []
        supp_specs << { :category => :remote,        :content=> "Reboot / KVM over IP" }
        supp_specs << { :category => :primary_ip,    :content=> "1 IP Address" }
        supp_specs << { :category => :host_ping,     :content=> "Host Ping" }
        supp_specs << { :category => :response,      :content=> "Automated Notification" }
        supp_specs << { :category => :notification,  :content=> "Email and Ticket" }
        supp_specs << { :category => :vpn,           :content=> "Unlimited SSL VPN Users & 1 PPTP VPN User per account" }
        supp_specs << { :category => :vulnerability, :content=> "Nessus Vulnerability Assessment & Reporting" }
        supp_specs
      end

      # fetch datacenter price ID
      def datacenter_for(dc_name)
        datacenters = @client[:Location_Datacenter].getDatacenters
        item  = datacenters.detect { |dc| dc["longName"].include?(dc_name) || dc["name"].include?(dc_name.downcase) }
        item["id"] unless item.nil?
      end

      def service_for(instance_type)
        case instance_type
        when INSTANCE_TYPES[:virtual_server][:name]  then  "Virtual_Guest"
        else                                               "Hardware_Server"
        end
      end

      def ssh_key_for(key_name)
        ssh_key =  @client[:Account].getSshKeys.detect { |k| k["label"] == key_name }
        raise "Cannot find SSH Key #{key_name} in Softlayer account !" if ssh_key.nil?
        ssh_key["id"]
      end
    end
end
end
