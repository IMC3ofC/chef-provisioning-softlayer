# IBM SoftLayer driver for Chef Provisioning

 A standalone IBM SoftLayer driver for chef-provisioning that doesn't use fog.

## Main functions

- It can provision, destroy and manipulate cloud instances on IBM SoftLayer
- Support customized system specificcation for __virtual server__, __bare metal instance__ and __bare metal server__
- Lately revision from __chef-provisioning__ v1.5


## Requirement

- A pair of IBM SoftLayer API username and key is required to use this driver
- Basic knowledge of IBM SoftLayer API, like what is virtual server, bare metal instance(hourly/monthly) and server(monthly)

## Quick Start

- Prerequisite  
  Abtain API username and key and export to environment variables or recipe (refer to __examples/cookbooks/test/recipes/virtual_server.rb__ recipe for details)

- How to run
```shell
  $ cd examples  
  $ chef-client -z -o test::virtual_server
```

## Limitation

- Assume user is responsible for correctness of specified system configuration of a cloud instance in recipe
- Due to loading meta data of IBM SoftLayer API, driver initialization might take minutes for bare metal server
- Support up to Chef 12.4

## Features/Functions to enhance

- Add 'why-run' support to help with debug or test
- Add Public/private key pair support

## Support

 Zhong Yu(Leo) Wu (leow@ca.ibm.com)   
 Emerging Technologies Team, IBM Analytics Platform (imcloud@ca.ibm.com)
 

## License

Apache v2.0