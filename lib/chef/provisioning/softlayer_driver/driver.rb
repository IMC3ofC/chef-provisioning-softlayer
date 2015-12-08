#
# Chef Provisioning driver for SoftLayer
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

require 'chef/mixin/shell_out'
require 'chef/provisioning/driver'
require 'chef/provisioning/machine/unix_machine'
require 'chef/provisioning/machine/basic_machine'
require 'chef/provisioning/machine_spec'
require 'chef/provisioning/convergence_strategy/install_sh'
require 'chef/provisioning/convergence_strategy/install_cached'
require 'chef/provisioning/convergence_strategy/no_converge'
require 'chef/provisioning/transport/ssh'
require 'chef/provisioning/softlayer_driver/helpers/cache'
require 'chef/provisioning/softlayer_driver/helpers/core'
require 'chef/provisioning/softlayer_driver/helpers/utils'
require 'cheffish/merged_config'
require 'softlayer_api'
require 'thread'

class Chef
module Provisioning
    # Provisions machines on SoftLayer
    class SoftlayerDriver < Chef::Provisioning::Driver

      include Chef::Mixin::ShellOut

      @@semaphore = Mutex.new
      @@sshkeys_search_dirs = [ "#{ENV['HOME']}/.softlayer_driver/keys",
                                "#{ENV['HOME']}/.chef/ssh",
                                "#{ENV['HOME']}/.ssh" ]
      def self.from_url(url, config)
        SoftlayerDriver.new(url, config)
      end

      def self.canonicalize_url(driver_url, config)
        # TODO: add other schema support later
        "softlayer"
      end

      def initialize(driver_url, config)
        Chef::Log.info "[SoftLayer_Driver#initialize] Initializing ... "

        super(driver_url, config)
        config = config.to_hash

        # Validate the initial inputs
        user_name   = config[:driver_options][:user_name]
        api_key     = config[:driver_options][:api_key]
        @instance_type = config[:driver_options][:instance_type]

        if user_name.nil? || api_key.nil? || !INSTANCE_IDX.any? {|inst| inst == @instance_type}
          error_exit "\n[softlayer_driver#initialize] Invalid driver options : #{config}"
        end

        @client = SoftLayer::Client.new(username: user_name,
                                        api_key: api_key,
                                        timeout: 600)
        @account        = nil
        @vguest         = nil
        @product_order  = nil

        # Load all required SoftLayer metadata for ordering later
        load_meta_data(@instance_type)

        Chef::Log.info "\n[softlayer_driver#initialize] Initializing ... Done !"
      end

      def allocate_machine(action_handler, machine_spec, machine_options)
      @@semaphore.synchronize {

        Chef::Log.info "\n[softlayer_driver#allocate_machine] allocate_machine ... "

        machine_options = machine_options.to_hash
        validate_options(machine_options)

        machine_spec.location = {}  if machine_spec.location.nil?
        machine_spec.location["instance_type"]  = @instance_type
        machine_spec.location["driver_url"]     = driver_url

        # set up provision time out
        if machine_options["provision_timeout"].nil? 
          machine_spec.location["provision_timeout"] = DEFAULT_OPTIONS[:provision_timeout][@instance_type.to_sym]
        else
          machine_spec.location["provision_timeout"] = machine_options[:provision_timeout]
        end

        # set up key if needed
        if action_handler.should_perform_actions
          machine_spec.location["key_name"] = machine_options.fetch(:key_name,nil)
          machine_spec.save(action_handler)
        end

        if machine_spec.location["provision_state"].nil? ||
           (machine_spec.location["id"].nil? && machine_spec.location["globalIdentifier"].nil?) 

          Chef::Log.info %(\n[softlayer_driver#allocate_machine] Machine #{machine_spec.name} not found in ./nodes/)

          action_handler.perform_action "[softlayer_driver#allocate_machine] Creating server #{machine_spec.name}" do
            server = create_node action_handler, machine_options, machine_spec
            if action_handler.should_perform_actions
              if server
                machine_spec.location["instance_type"] = @instance_type
                case @instance_type
                when INSTANCE_TYPES[:virtual_server][:name]
                  machine_spec.location["id"] = server[:id]
                else
                  machine_spec.location["globalIdentifier"]  =  server[:globalIdentifier]
                end

                machine_spec.location["provision_state"]  =  server[:provision_state]
                Chef::Log.info %(\n[softlayer_driver#allocate_machine] #{machine_spec.name} - Instance Initialized !)

                # save machine space for imdempotence
                machine_spec.save(action_handler)
              end
            else
              Chef::Log.info %(\n[softlayer_driver#allocate_machine] Running why-run mode ... machine_options are verified !)
            end  
          end
        else
          Chef::Log.info %(\n[softlayer_driver#allocate_machine] Machine #{machine_spec.name} found in ./nodes/)
          if machine_options["reload_os"]
            Chef::Log.info %(\n[SLDriver#allocate_machine] reload OS ... )
            machine_spec.location["provision_state"] = PROVISION_STATE[:INIT]
            reload_os_instance(machine_spec)
            Chef::Log.info %(\n[SLDriver#allocate_machine] reload OS ... submitted)
          end
        end

        Chef::Log.info %(\n[softlayer_driver#allocate_machine] allocate_machine ... Done !)
        machine_spec

      }
      end

      def ready_machine(action_handler, machine_spec, machine_options)
        Chef::Log.info "\n[softlayer_driver#ready_machine] ready_machine ..."
        # clean up known_host file
        if action_handler.should_perform_actions

          if machine_spec.location["provision_state"] == PROVISION_STATE[:INIT]
            query_provision_state(action_handler, machine_spec)
            Chef::Log.info %(\n[softlayer_driver#ready_machine] #{machine_spec.name} -  created !)
          elsif machine_spec.location["provision_state"] == PROVISION_STATE[:DONE]
              server = server_for machine_spec
              error_exit "[softlayer_driver#ready_machine] Invalid Server !" if server.nil? || server[:power].nil?
              if server[:power].upcase == SERVER_STATE[:RUNNING] ||
                server[:power].upcase == SERVER_STATE[:ON]
                Chef::Log.info %(\n[softlayer_driver#ready_machine] Machine is powered on and waiting for #{machine_spec.name} ready ...)
                wait_until_ready machine_spec
              else
                start_machine = %([softlayer_driver#ready_machine] Starting machine #{machine_spec.name}  ...)
                Chef::Log.info start_machine
                action_handler.perform_action start_machine do
                  start_instance server[:id], @instance_type
                end

                wait_for_machine = %([softlayer_driver#ready_machine] Machine is started and waiting for machine #{machine_spec.name} ready ...)
                Chef::Log.info wait_for_machine
                action_handler.perform_action wait_for_machine do
                  wait_until_ready machine_spec
                end
              end
          else
            error_exit "[softlayer_driver#ready_machine] #{machine_spec.name} is in an invalid state !"
          end

          Chef::Log.info %(\n[softlayer_driver#ready_machine] ready_machine ... Done !)

          cleanup_host machine_spec
        else
          # create a dummy/place holder machine to avoid raising an error
          Chef::Log.info "[softlayer_driver#allocate_machine] running in why-run mode ... skipped !"
          return nil
        end

        # Return the Machine object
        machine_for(machine_spec, machine_options)
      end

      # Connect to a machine without acquiring it. This method will NOT make any changes to anything.
      # Parameters:
      #   - machine_spec: machine_spec object (deserialized JSON) to save this needed machine information
      #   - machine_options:  machine specific options to provision a cloud instance 
      def connect_to_machine(machine_spec, machine_options)
        machine_for(machine_spec, machine_options)
      end

      # Delete the given machine (idempotent). Should destroy the machine, 
      # returning things to the state before allocate_machine was called.
      def destroy_machine(action_handler, machine_spec, machine_options)
        Chef::Log.info %(\n[softlayer_driver#destroy_machine] Destroying machine ...)
        
        error_exit "machine is in an invalid state !" if machine_spec.location["provision_state"] != PROVISION_STATE[:DONE]

        if machine_spec.location
          server_id = machine_spec.location["id"]
          action_handler.perform_action "Destroy machine #{server_id} ..." do
            delete_instance machine_spec
          end
        end

        Chef::Log.info %(\n[softlayer_driver#destroy_machine] Destroying machine ... Done !)
        strategy = convergence_strategy_for(machine_spec, machine_options)
        strategy.cleanup_convergence(action_handler, machine_spec)
        machine_spec.location = nil

      end

      def stop_machine(action_handler, machine_spec, machine_options)
        Chef::Log.info %(\n[softlayer_driver#destroy_machine] Stopping machine ...)

        if machine_spec.location
          server_id = machine_spec.location["id"]
          action_handler.perform_action "Power off machine #{server_id}" do
            stop_instance machine_spec.location["id"], machine_spec.location["instance_type"]
          end
        end

        Chef::Log.info %(\n[softlayer_driver#destroy_machine] Stopping machine ... Done !)

      end

    protected

      def server_for(machine_spec)
        unless machine_spec.location.nil?
          query_node machine_spec
        end
      end

      def machine_for(machine_spec, machine_options, server=nil)
        unless machine_spec.location["provision_state"].nil?
          require "chef/provisioning/machine/unix_machine"
          ChefMetal::Machine::UnixMachine.new machine_spec, transport_for(machine_spec), 
                                              convergence_strategy_for(machine_spec, machine_options)
        end
      end

      def convergence_strategy_for(machine_spec, machine_options)
        if machine_spec.location["provision_state"] == PROVISION_STATE[:DONE]
          if machine_options[:convergence_options][:chef_version]
            require "chef/provisioning/convergence_strategy/install_cached"
            ChefMetal::ConvergenceStrategy::InstallCached.new machine_options[:convergence_options], config
          else
            require "chef/provisioning/convergence_strategy/install_sh"
            ChefMetal::ConvergenceStrategy::InstallSh.new machine_options[:convergence_options], config
          end
        end
      end

      # do transport on public interface ONLY
      def transport_for(machine_spec)
        create_ssh_transport machine_spec
      end

      def create_ssh_transport(machine_spec)
        require "chef/provisioning/transport/ssh"

        username  = machine_spec.location["username"]
        private_path = nil
        unless  machine_spec.location["key_name"].nil?
          key_name = machine_spec.location["key_name"]
          @@sshkeys_search_dirs.each do |dir|
            private_path = "#{dir}/#{key_name}"
            if File.exist?(private_path)
              break
            else
              private_path = nil
            end
          end
          raise "Can not find private key file for #{key_name} !" if private_path.nil?
        end

        password    = machine_spec.location["password"] if private_path.nil?
        ip_address  = machine_spec.location["ip_address"]

        if private_path.nil?
          ssh_options = { password: password }
        else
          ssh_options = { key_data: IO.read(private_path).to_s, keys_only: TRUE }
        end
        options = {}

        ChefMetal::Transport::SSH.new ip_address, username, ssh_options, options, config
      end

    private
      #
      ## validate machine options provided
      # 
      def validate_options(options)
       
        error_exit "[softlayer_driver#validate_options] Error: billing_period is missing !"  if options[:billing_period].nil?
        error_exit "[softlayer_driver#validate_options] Error: os_name is missing !"  if options[:os_name].nil?
        error_exit "[softlayer_driver#validate_options] Error: ram is missing !" if options[:ram].nil?

        if !options[:private_key].nil? && options[:public_key].nil?
          error_exit "[softlayer_driver#validate_options] Error: public key is missing !" 
        end

        if options[:datacenter].nil? || datacenter_for(options[:datacenter]).nil?
          error_exit "[softlayer_driver#validate_options] Error: datacenter is missing or invalid !"
        end
        
        if options[:storage].nil? || 
           options[:storage][:server_disks].nil? ||
           options[:storage][:server_disks].empty?
          error_exit "[softlayer_driver#validate_options] Error: storage is missing or invalid !"
        end

        if options[:cpu].nil? || options[:cpu][:cores].nil?
          error_exit "[softlayer_driver#validate_options] Error: cpu is missing  or invalid !"
        end

        
        
        if @instance_type == INSTANCE_TYPES[:bare_metal_server][:name] 
          if options[:cpu][:type].nil?
            error_exit "[softlayer_driver#validate_options] Error: cpu type is missing for bare metal server !"
          end

          if !options[:billing_period].nil? &&
              options[:billing_period] == BILLING_TYPE[:hourly]
            error_exit "[softlayer_driver#validate_options] Error: billing_period is invalid for bare metal server !"
          end

          if options[:storage][:storage_groups].nil? ||
             options[:storage][:server_disks_max].nil? ||
             options[:storage][:server_disks_max].to_i < options[:storage][:server_disks].size
            error_exit "[softlayer_driver#validate_options] Error: storage is invalid for bare metal server !"
          end
        end

        if options[:network].nil? || 
           options[:network][:domain].nil? || 
           options[:network][:hostname].nil? 
          error_exit "[softlayer_driver#validate_options] Error: network is missing !"
        end

      end

      #
      ## check node provision state until ready
      ## dedicated for bare metal
      #
      def query_provision_state(action_handler, machine_spec)
        count = 0
        provision_timeout = machine_spec.location["provision_timeout"].to_i
        loop do
          # raise error if time out
          error_exit "machine provision time out ... #{provision_timeout/60} minutes" if (count += 1) > provision_timeout/60

          server = query_node(machine_spec)
          unless server.nil?
            machine_spec.location["id"]  =  server[:id]
            machine_spec.location["ip_address"]         =  server[:ip_address] unless server[:ip_address].nil?
            machine_spec.location["username"]           =  server[:username]   unless server[:username].nil?
            machine_spec.location["password"]           =  server[:password]   unless server[:password].nil?
            machine_spec.location["provision_state"]    =  PROVISION_STATE[:DONE]

            Chef::Log.info %(\softlayer_driver#query_provision_state] #{machine_spec.name} - Instance created !)

            # save node for imdempotence
            machine_spec.save(action_handler)

            break
          end

          Chef::Log.info %(\n[softlayer_driver#query_provision_state] #{machine_spec.name} - Transaction in progress for #{count} minutes ...)
          sleep 60
        end
      end

      def error_exit(error_txt)
        Chef::Log.error error_txt
        fail error_txt
      end
  end
end
end
