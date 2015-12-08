#
# Chef Provisioning driver for SoftLayer
#
# Functions: cache meta data of SoftLayer API in memory
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
    
    class SoftlayerDriver < Chef::Provisioning::Driver
  
      private

      def init_metadata_hash
        @objectOptions_vm = {}
        @objectOptions_bmi = {}
        @bms_packages = {}
        @productitem_cache = []
      end

      #
      #  Metadata definition in SoftLayer API
      #
      #  1. Object option for ordering is ONLY available for
      #     virtual server and bare metal instance
      #  2. Only meta data of item can be used to order bare metal server
      # 
      #  So load meta data for ordering in different ways
      #
      def load_meta_data(instance_type)
        init_metadata_hash()
        case instance_type
        when INSTANCE_TYPES[:bare_metal_server][:name]
          packages = SoftLayer::ProductPackage.bare_metal_server_packages(@client)
          packages.each do |pkg|
               print "."
               cache_bms_packages pkg
          end
        when INSTANCE_TYPES[:bare_metal_instance][:name]
          @objectOptions_bmi = @client[:Hardware_Server].getCreateObjectOptions
        when INSTANCE_TYPES[:virtual_server][:name]
          @objectOptions_vm = @client[:Virtual_Guest].getCreateObjectOptions
        end
      end

      def cache_bms_packages(package)
        disks_max = package.service.getAvailableStorageUnits

        # add available storage units as self-defined product item
        cache_product_item package.id,
                           "Disk Available Storage Units",
                           CATEGORY_ID[:disks_max],
                           1,
                           CATEGORY_ID[:disks_max],
                           "#{disks_max} Available Storage Units"

        all_categories  = package.service.object_mask("mask[itemCategory, isRequired]").getConfiguration
        item_prices     = package.service.object_mask("mask[id, item.description, categories.id]").getItemPrices

        all_categories.each do |configuration_entry|
          category_name     = configuration_entry["itemCategory"]["name"]
          category_id       = configuration_entry["itemCategory"]["id"]
          category_required = configuration_entry["isRequired"]

          item_prices.each do |item_price|
            next unless item_price["categories"]
            if item_price["categories"].any? { |category| category["id"] == category_id }
              item_description  = item_price["item"]["description"]
              
              cache_product_item package.id,
                                 category_name,
                                 category_id,
                                 category_required,
                                 item_price["id"],
                                 item_description
            end
          end
        end
      end

      ##
      ## cache all product items of bare metal server
      ##
      def cache_product_item(package_id, category_name, category_id, 
                             category_required, productitem_id, productitem_desc)

        product_item = @productitem_cache.detect do |p|
          p[:package_id]    == package_id &&
          p[:category_id]   == category_id &&
          p[:productiem_id] == productitem_id
        end

        product_item ||= {}
        product_item[:package_id]        = package_id
        product_item[:category_name]     = category_name
        product_item[:category_id]       = category_id
        product_item[:category_required] = category_required
        product_item[:productitem_id]    = productitem_id
        product_item[:productitem_desc]  = productitem_desc

        @productitem_cache.push product_item

        # organize all items by package
        if @bms_packages[package_id].nil?
          @bms_packages[package_id] = []
        end

        @bms_packages[package_id] << product_item
      end

      #
      ## Look up Object options
      def lookup_object_options(options)
        order_template = {}
        localDiskFlag  = true

        case @instance_type
        when INSTANCE_TYPES[:virtual_server][:name]
          order_template.merge!(lookup_common_object_options(@objectOptions_vm, options))

          item = @objectOptions_vm["memory"].detect { |ram| ram["template"]["maxMemory"].to_i == options[:ram].to_i*1024 }
          order_template.merge!(item["template"]) unless item.nil?

          if options[:cpu][:private].nil?
            item = @objectOptions_vm["processors"].detect { |proc| proc["template"]["startCpus"].to_i == options[:cpu][:cores].to_i }
          else
            item = @objectOptions_vm["processors"].detect { |proc| proc["template"]["startCpus"].to_i == options[:cpu][:cores].to_i &&
                                                                   proc["template"]["dedicatedAccountHostOnlyFlag"] == options[:cpu][:private] }
          end  
          order_template.merge!(item["template"]) unless item.nil?

          # set up localDiskFlag
          server_disks = options[:storage][:server_disks]
          localDiskFlag = false if server_disks.detect { |d| d[:type].include?"SAN" }
          order_template.merge!({ 'localDiskFlag' => localDiskFlag })

          # Loop disks to set up blockDevices options
          disks_template = []
          server_disks.each_with_index do |disk, index|
            index += 1 if index > 0
            item = @objectOptions_vm["blockDevices"].detect { |dev| dev["template"]["localDiskFlag"] == localDiskFlag &&
                                                                    dev["template"]["blockDevices"].first["device"].to_i == index &&
                                                                    dev["template"]["blockDevices"].first["diskImage"]["capacity"].to_i == disk[:capacity].to_i }
            disks_template << item["template"]["blockDevices"].first unless item.nil?
          end
          order_template.merge!({ "blockDevices" => disks_template }) unless disks_template.empty?
        when INSTANCE_TYPES[:bare_metal_instance][:name]

          order_template.merge!(lookup_common_object_options(@objectOptions_bmi, options))

          order_template.merge!(@objectOptions_bmi["hardDrives"][0]["template"])

          item = @objectOptions_bmi["processors"].detect { |proc| proc["template"]["memoryCapacity"].to_i == options[:ram].to_i &&
                                                                  proc["template"]["processorCoreAmount"].to_i == options[:cpu][:cores].to_i }
          order_template.merge!(item["template"]) unless item.nil?       
        end
        order_template
      end

      def lookup_common_object_options(objectOptions, options)
        common_template = {}
        item = objectOptions["datacenters"].detect { |dc| dc["template"]["datacenter"]["name"].include?options[:datacenter] }

        common_template.merge!(item["template"]) unless item.nil?

        item = objectOptions["networkComponents"].detect { |net| net["template"]["networkComponents"].first["maxSpeed"].to_i == options[:network][:speed].to_i }
        common_template.merge!(item["template"]) unless item.nil?

        item = objectOptions["operatingSystems"].detect { |os| os["itemPrice"]["item"]["description"].include?(options[:os_name]) }
        common_template.merge!(item["template"]) unless item.nil?
      end

      #
      ## look up product items for bare metal servers ONLY
      #
      def lookup_product_items(specs, pkg_id = nil)
        @bms_packages.each do |key,value|
          next if !pkg_id.nil? && pkg_id != key
  
          found_in_package = true
          prices_id = {}
          compares = []
          prices_id["package_id"] = key
          prices_id["ids"] = []

          specs.each do |spec|
            category_id, regex =
              case spec[:category]
              when :os               then    c, r = CATEGORY_ID[:os],               /^#{spec[:content].gsub("(", "\\(").gsub(")", "\\)")}$/
              when :bms_cpu          then    c, r = CATEGORY_ID[:bms_cpu],          /^(.*)#{spec[:content][:cpu_type]}(.*)#{spec[:content][:cores].to_i} Cores(.*)/
                                                                                    
              when :ram              then    c, r = CATEGORY_ID[:ram],              /^#{spec[:content]} GB/
              when :bms_raid         then    c, r = CATEGORY_ID[:bms_raid],         /^#{spec[:content]}$/
              when :bms_disk         then    c, r = CATEGORY_ID[:bms_disks][spec[:content][:seq_id]].to_i,  /^#{spec[:content][:desc]}/
              when :bms_disk_max     then    c, r = CATEGORY_ID[:disks_max],        /^#{spec[:content]} Available Storage Units$/
              when :bandwidth        then    c, r = CATEGORY_ID[:bandwidth],        /^#{spec[:content]}$/
              when :network          then    c, r = CATEGORY_ID[:network],          /^#{spec[:content].gsub("&", "\\&")}$/
              when :remote           then    c, r = CATEGORY_ID[:remote],           /^#{spec[:content].gsub("/", "\\/")}$/
              when :primary_ip       then    c, r = CATEGORY_ID[:primary_ip],       /^#{spec[:content]}$/
              when :host_ping        then    c, r = CATEGORY_ID[:host_ping],        /^#{spec[:content]}$/
              when :response         then    c, r = CATEGORY_ID[:response],         /^#{spec[:content]}$/
              when :notification     then    c, r = CATEGORY_ID[:notification],     /^#{spec[:content]}$/
              when :vpn              then    c, r = CATEGORY_ID[:vpn],              /^#{spec[:content].gsub("&", "\\&")}$/
              when :vulnerability    then    c, r = CATEGORY_ID[:vulnerability],    /^#{spec[:content].gsub("&", "\\&")}$/
              else                   return nil
              end
            compares << { :category_id => category_id, :regex => regex }
          end

          compares.each do |cmp|
            product_item  =  value.detect  do |p|
              p[:category_id]       == cmp[:category_id] &&
              p[:productitem_desc]  =~ cmp[:regex]
            end

            if product_item.nil?
              # puts "#{cmp[:regex]} - #{cmp[:category_id]} is NOT found !"
              found_in_package = false
              break
            else
              # puts "#{cmp[:regex]} - #{cmp[:category_id]} is found !"
              # skip availabel storage Unit since it's a placeholder created by us
              next if product_item[:productitem_id] == CATEGORY_ID[:disks_max]
              prices_id["ids"] << { "id" => product_item[:productitem_id] }
            end
          end  # end of compare loop     

          if found_in_package
            # check if power supply is required
            power_supply_item = value.detect do |p|
              p[:package_id]  == key &&
              p[:category_id] == CATEGORY_ID[:power_supply] &&
              p[:category_required]
            end

            # add power supply if required
            unless power_supply_item.nil?
              prices_id["ids"] << { "id" => power_supply_item[:productitem_id] }
            end

            return prices_id
          else
            next
          end

        end # end of bms_packages loop

        Chef::Log.error "[softlayer_driver#lookup_product_items] Could not find system spec : \n '#{specs}'"
        nil
      end
    end
end
end
