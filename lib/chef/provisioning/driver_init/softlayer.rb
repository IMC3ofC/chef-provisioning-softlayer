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

require 'chef/provisioning/softlayer_driver/driver'

Chef::Provisioning.register_driver_class("softlayer", Chef::Provisioning::SoftlayerDriver)