#
# Chef Provisioning driver for SoftLayer
#
#
# Functions: provision and manipulate cloud instance
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

      def create_node(action_handler, machine_options, machine_spec)
        case  @instance_type
        when  INSTANCE_TYPES[:bare_metal_server][:name]
          instance = create_instance_bms(action_handler, machine_options, machine_spec)
        else
          instance = create_instance(action_handler, machine_options, machine_spec)
        end
        instance
      end

      #
      ## Generate order template of virtual server or bare metal instance
      #
      def acquireOrderTemplate(options)
        order_template = lookup_object_options(options)
        order_template.merge!({ "hostname" => options[:network][:hostname] })
        order_template.merge!({ "domain"   => options[:network][:domain] })
        order_template.merge!({ "hourlyBillingFlag" => (options[:billing_period] == BILLING_TYPE[:hourly]) })

        # if template provided, remove OS and blockDevice options
        unless options[:template_id].nil?
          template_object = { "globalIdentifier" => options[:template_id] }
          order_template.merge!({ "blockDeviceTemplateGroup" => template_object })
          order_template.delete("operatingSystemReferenceCode")
          order_template.delete("blockDevices")
        end 

        unless options[:key_name].nil?
          sshkeys = []
          sshkeys << { "id" => ssh_key_for(options[:key_name]) }
          order_template.merge!({ "sshKeys" => sshkeys })
        end

        begin
          @client[service_for(@instance_type).to_sym].generateOrderTemplate(order_template)
        rescue => exception
          error_exit "[softlayer_driver#acquireOrderTemplate] Can not find system specification from machine_options, error: #{exception}"
        end
      end

      #
      ## Generate template order of bare metal server
      #  Note:
      #    we retrieve price ID of the required product items 
      #  and generate a SoftLayer_Product_Order object
      #
      def acquireOrderTemplate_bms(options)
        datacenter       = datacenter_for(options[:datacenter])
        cores            = options[:cpu][:cores]
        ram              = options[:ram]
        os_name          = options[:os_name]
        template_id      = options.fetch(:template_id, nil)
        disks            = options[:storage][:server_disks]

        hostname         = options[:network][:hostname]
        domain           = options[:network][:domain]
        bandwidth        = options.fetch(:network).fetch(:bandwidth, DEFAULT_OPTIONS[:bandwidth])
        network_speed    = options.fetch(:network).fetch(:network_speed,  DEFAULT_OPTIONS[:network_speed])
        public_key       = options.fetch(:public_key,nil)
        hourly_billing   = (options.fetch(:billing_period, DEFAULT_OPTIONS[:billing_period])) == BILLING_TYPE[:hourly]

        disks_max = options[:storage][:server_disks_max]
        raids     = options.fetch(:storage).fetch(:storage_groups)
        cpu_type  = options[:cpu][:type]

        specs = [
                   { :category => :bms_cpu,       :content => { :cores => cores, :cpu_type => cpu_type } },
                   { :category => :ram,           :content => ram },
                   { :category => :os,            :content => os_name },
                   { :category => :network,       :content => network_speed },
                   { :category => :bandwidth,     :content=>  bandwidth }
                ]
        specs << supplemental_specs

        disks.each do |dk|
           specs << { :category => :bms_disk, :content => { :seq_id => dk[:seq_id].to_i, :desc => dk[:description] } }
        end

        raids_items = raids.select { |raid| raid[:type] =~ /^RAID(.*)/ }
        # we need to specify RAID type ONLY if there is one RAID,
        # otherwise, it uses a generic RAID controller for multiple RAIDs
        unless raids_items.nil? 
          if raids_items.size == 1
            specs << { :category => :bms_raid, :content => raids_items.first[:type] }
          else
            specs << { :category => :bms_raid, :content => "Non-RAID" }
          end
        end

        # add available storage units if needed
        specs << { :category => :bms_disk_max, :content=> "#{disks_max}" } unless disks_max.nil?

        # puts "specs = #{specs}"
        prices_ids  = lookup_product_items(specs)
        if prices_ids.nil? || !(prices_ids.is_a? Hash) || prices_ids["ids"].nil?
          error_exit "[softlayer_driver#generateOrderTemplate_bms] The requested system specification is NOT found in IBM SoftLayer ! \nspecs: #{specs}"
        else
          product_order["packageId"] = prices_ids["package_id"]
          product_order["prices"] = []
          product_order["prices"].concat(prices_ids["ids"])
        end

        product_order = {
          "complexType"       => "SoftLayer_Container_Product_Order_Hardware_Server",
          "quantity"          => 1,
          "hardware" => [
            {
              "hostname"      => hostname,
              "domain"        => domain
            }
          ],
          "location"          => datacenter,
          "useHourlyPricing"  => hourly_billing          
        }

        product_order["imageTemplateGlobalIdentifier"] = template_id unless template_id.nil?
        product_order["sshkeys"] = { "sshKeyIds" => [ssh_key_for(hostname, public_key)["id"]] } unless public_key.nil?

        # set default RAID if multiple storage groups
        if !raids_items.nil? && raids_items.size > 1
          specs = [ { :category => :bms_raid,  :content => "RAID" } ]
          prices_ids = lookup_product_items(specs, prices_ids["package_id"])
          product_order["prices"] << prices_ids["ids"].first unless prices_ids.nil?
            product_order["storageGroups"] = []

            # construct storageGroups
            raids.each do |raid|
              rd_array = {}
              rd_array["arrayTypeId"] = DISK_ATTR_TYPE_ID[raid["type"]]
              rd_array["hardDrives"]  = []
              raid[:hard_drives].each do |hd|
                rd_array[:hard_drives] << hd.to_i
              end
              product_order["storageGroups"] << rd_array unless rd_array.nil?
            end
        end
        product_order
      end

      #
      ## simply construct and place an order upon given options
      ## which serves for virtual server, bare metal instance and server
      def place_order(action_handler, options, machine_spec)
        #
        # Generate an order template to verify/place order later
        #  Note:
        #    Due to uniquess of ordering bare metal server via SoftLayer API, 
        #    we have to differentiate order template generation process
        # 
        #  1. virtual server and bare metal instance,
        #     - Retrieve object options to generate order 
        #
        #  2. bare metal server
        #     - Query available price/product item ID to generate an order template
        #
        case @instance_type
        when INSTANCE_TYPES[:bare_metal_server][:name]
            order_container = acquireOrderTemplate_bms(options)
        else
            order_container = acquireOrderTemplate(options)
        end

        begin
          @product_order ||= @client[:Product_Order]
          client_order = @product_order.verifyOrder order_container
          Chef::Log.debug "[softlayer_driver#place_order] Order is verified successfully!"

          if action_handler.should_perform_actions
            client_order = @product_order.placeOrder order_container
            Chef::Log.debug "[softlayer_driver#place_order] Order is placed successfully!"           
          end

        rescue => exception
          error_exit "[softlayer_driver#place_order] Failed with: #{exception}"
        end
        client_order
      end

      #
      ## create cloud instance of virtual server or bare metal instance
      #
      def create_instance(action_handler, options, machine_spec)
        client_order = place_order(action_handler, options, machine_spec)

        if action_handler.should_perform_actions

          # Sleep 1 minute to make sure to retrieve metrics of virtual guest,
          # otherwise it may fail. Maybe a bug on Softlayer API
          sleep 60

          # retrieve server id
          if @instance_type == INSTANCE_TYPES[:virtual_server][:name]
            # Retrieve id of virtual guest
            instance = client_order["orderDetails"]["virtualGuests"].first unless client_order.nil?
          elsif @instance_type == INSTANCE_TYPES[:bare_metal_instance][:name]
            instance = client_order["orderDetails"]["hardware"].first unless client_order.nil?
          end

          # set up notes
          notes  = options.fetch(:notes,nil)
          unless notes.nil?
             template_object = { "notes" => notes }
             @cloud_instance ||= @client[service_for(@instance_type).to_sym]
             @cloud_instance.object_with_id(instance["id"]).editObject(template_object)
          end

          if @instance_type == INSTANCE_TYPES[:virtual_server][:name]
          {
            id:                 instance["id"],
            provision_state:    PROVISION_STATE[:INIT]
          }
          elsif @instance_type == INSTANCE_TYPES[:bare_metal_instance][:name]
          {
            globalIdentifier:   instance["globalIdentifier"],
            provision_state:    PROVISION_STATE[:INIT]
          }
          end
        else
          error_exit "[softlayer_driver#create_instance] why_run not supported !"
        end
      end

      #
      ## create cloud instance of bare metal server
      #

      def create_instance_bms(action_handler, options, machine_spec)
        client_order = place_order(action_handler, options, machine_spec)

        if action_handler.should_perform_actions
          # Only globalIdentifier is generated right after order a bare metal server
          # server id is generated hours later while provisioning
          instance = client_order["orderDetails"]["hardware"].first unless client_order.nil?

          # set up notes
          notes  = options.fetch(:notes,nil)
          unless notes.nil?
             template_object = { "notes" => notes }
             @cloud_instance ||= @client[service_for(@instance_type).to_sym]
             @cloud_instance.object_with_id(instance["id"]).editObject(template_object)
          end

          # return instance with globalIdentifier
          {
            globalIdentifier:   instance["globalIdentifier"],
            provision_state:    PROVISION_STATE[:INIT]
          }
        else
          error_exit "[softlayer_driver#create_instance_bms] why_run not supported !"
        end
      end

     def start_node(identifier, instance_type)
        case  instance_type
        when  INSTANCE_ATTR[:virtual_server][:TYPE]
          start_instance(identifier)
        else
          start_instance_bm(identifier)
        end
     end

     def start_instance(identifier)
        @vguest ||= @client[:Virtual_Guest]
        begin
          @vguest.object_with_id(identifier).powerOn
          # TODO: Test raise exception from here.
          # Should the exception be rescued or just raised to top level?
        rescue => exception
          error_exit "[softlayer_driver#start_instance] Failed with: #{exception}"
        end
      end

      def start_instance_bm(identifier)
        @softlayer_hw ||= @client[:hardware]
        begin
          @softlayer_hw.object_with_id(identifier).powerOn
          # TODO: Test raise exception from here.
          # Should the exception be rescued or just raised to top level?
        rescue => exception
          error_exit "[softlayer_driver#start_instance_bm] Failed with: #{exception}"
        end
      end

      def stop_node(identifier, instance_type)
        case  instance_type
        when  INSTANCE_ATTR[:virtual_server][:name]
          stop_instance(identifier)
        else
          stop_instance_bm(identifier)
        end
      end

      def stop_instance(identifier)
        @vguest ||= @client[:Virtual_Guest]
        begin
          @vguest.object_with_id(identifier).powerOffSoft
        rescue => exception
          error_exit "[softlayer_driver#stop_instance] Failed with: #{exception}"
        end
      end

      def stop_instance_bm(identifier)
        @softlayer_hw ||= @client[:hardware]
        begin
          @softlayer_hw.object_with_id(identifier).powerOff
        rescue => exception
          error_exit "[softlayer_driver#stop_instance_bm] Failed with: #{exception}"
        end
      end

      def delete_node(machine_spec)
        if machine_spec.location["instance_type"] == INSTANCE_ATTR[:virtual_server][:TYPE]
          delete_instance(machine_spec)
        else
          delete_instance_bm(machine_spec)
        end
      end

      def delete_instance(machine_spec)
      @@semaphore.synchronize {

        @softlayer_instance ||= @client[:Virtual_Guest]
        begin
          @softlayer_instance.object_with_id(machine_spec.location["id"]).deleteObject
        rescue => exception
          error_exit "[softlayer_driver#delete_instance] Failed with: #{exception}"
        end

      }
      end

      def delete_instance_bm(machine_spec)
      @@semaphore.synchronize {

        @softlayer_instance ||= @client[:Hardware_Server]
        @softlayer_bill     ||= @client[:Billing_Item]
        begin
          bill = @softlayer_instance.object_with_id( machine_spec.location["id"]).getBillingItem
          @softlayer_bill.object_with_id(bill["id"]).cancelItem(false,true,CANCELLATION_REASONS["unneeded"])
        rescue => exception
          error_exit "[softlayer_driver#delete_instance_bms] Failed with: #{exception}"
        end

      }
      end

      def query_node(machine_spec)
        case machine_spec.location["instance_type"]
        when INSTANCE_TYPES[:virtual_server][:name]
          query_instance(machine_spec.location["id"].to_s)
        else
          query_instance_bm(machine_spec.location["globalIdentifier"].to_s)
        end
      end

      def query_instance(identifier)
      @@semaphore.synchronize {

        @vguest ||= @client[:Virtual_Guest]
        begin
          vguest = @vguest.object_with_id(identifier)
          transaction = vguest.getActiveTransactions
          return nil if transaction && transaction.any?

          unless vguest.nil?
            os = vguest.object_mask("mask[passwords]").getOperatingSystem
            {
              id:         identifier.to_s,
              ip_address: vguest.getPrimaryIpAddress.to_s,
              hostname:   vguest.getObject["fullyQualifiedDomainName"].to_s,
              username:   (os_username = os["passwords"][0]["username"] rescue ""), 
              password:   (os_password = os["passwords"][0]["password"] rescue ""),
              power:      vguest.getPowerState["keyName"].to_s
            }
          end
        rescue => exception
          error_exit "[softlayer_driver#query_instance] Failed with: #{exception}"
        end

      }
      end

      def query_instance_bm(globalIdentifier)
      @@semaphore.synchronize {

        @account ||=  @client[:Account]
        begin
          hwservers = @account.getHardware
          hwserver  = hwservers.detect { |hw| hw["globalIdentifier"].to_s == globalIdentifier.to_s }
          if hwserver.nil?
            return nil
          else
            return nil if hwserver["hardwareStatus"]["status"] != "ACTIVE"

            bmserver = @client[:Hardware_Server]
            bm = bmserver.object_with_id(hwserver["id"].to_i)
            os = bm.object_mask("mask[passwords]").getOperatingSystem

            server = {
                       id:          hwserver["id"],
                       ip_address:  hwserver["primaryIpAddress"],
                       hostname:    hwserver["fullyQualifiedDomainName"],
                       username:    os["passwords"].first["username"],
                       password:    os["passwords"].first["password"],
                       power:       bm.getServerPowerState.to_s
                     }
          end
          server
        rescue => exception
          error_exit "[softlayer_driver#query_bms] Failed with: #{exception}"
        end

      }
      end

      def reload_os_node(machine_spec)
        case machine_spec.location["instance_type"]
        when INSTANCE_ATTR[:virtual_server][:TYPE]
          reload_os(machine_spec.location["id"])
        else
          reload_os_bm(machine_spec.location["globalIdentifier"])
        end
      end

      def reload_os(identifier)
        @vguest ||= @client[:Virtual_Guest]

        begin
          vguest = @vguest.object_with_id(identifier)
          vguest.reloadCurrentOperatingSystemConfiguration
        rescue => exception
          error_exit "[softlayer_driver#reload_os] Failed with: #{exception}"
        end
      end

      def reload_os_bm(identifier)
        @account ||=  @client[:Account]

        begin
          hwservers = @account.getHardware
          hwserver  = hwservers.detect { |hw| hw["globalIdentifier"].to_s == globalId.to_s }
          if hwserver.nil?
            return nil
          else
            return nil if hwserver["hardwareStatus"]["status"] != "ACTIVE"

            bmserver = @client[:Hardware_Server]
            bms = bmserver.object_with_id(hwserver["id"].to_i)
            bms.reloadCurrentOperatingSystemConfiguration
          end
        rescue => exception
          error_exit "[softlayer_driver#reload_os_bms] Failed with: #{exception}"
        end
      end
    end
end
end
