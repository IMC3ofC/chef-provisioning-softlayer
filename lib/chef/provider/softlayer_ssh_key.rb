require 'softlayer_api'
require 'chef/provider/lwrp_base'
require 'openssl'

class Chef::Provider::SoftlayerSshKey < Chef::Provider::LWRPBase

  @@sshkeys_search_dirs = [ "#{ENV['HOME']}/.softlayer_driver/keys", 
                            "#{ENV['HOME']}/.chef/ssh", 
                            "#{ENV['HOME']}/.ssh" ]

  use_inline_resources

  def whyrun_supported?
    false
  end

  action :create do
    create_key(new_resource.name)
  end
  
  def create_key(name)
    softlayer_key = find_softlayer_key(name)
    local_key     = find_local_key(name)

    if softlayer_key
      if local_key
        raise "Public keys don't match" unless (local_key.strip == softlayer_key.strip)
      else
        raise "SSH key #{name} missing"
      end
    else
      create_local_key(name) unless local_key
      begin
        create_softlayer_key(name)
      ensure
        delete_local_key(name) unless local_key
      end
    end
  end

  protected

  def is_valid_credentail(username, api_key)
    begin
       @@client ||= SoftLayer::Client.new(username: username, api_key: api_key, timeout: 600)
       status = @@client[:Account].getAccountStatus
       return status["name"] == "Active"
    rescue => e
       raise "#{e.inspect} for user '#{username}'"
    end
    return false
  end

  def find_softlayer_key(name)
    username = new_resource.softlayer_username
    api_key  = new_resource.softlayer_api_key
    
    if username.nil? || api_key.nil?
      raise "username or api_key for SoftLayer API is blank !" 
    end

    unless is_valid_credentail(username, api_key)
      raise "Invalid username or api_key of SoftLayer API !"
    end

    @@client ||= SoftLayer::Client.new(username: username, api_key: api_key, timeout: 600)
    account = @@client[:Account]
    ssh_key = account.getSshKeys.detect { |k| k["label"] == name }
    if ssh_key
      return ssh_key["key"]
    else
      return nil
    end
  end

  # ~/.softlayer/keys
  # ~/.chef/ssh
  # ~/.ssh
  def find_local_key(name)
    
    @@sshkeys_search_dirs.each do |dir|
      public_key_path  = Dir.glob("#{dir}/#{name}.pub")
      private_key_path = Dir.glob("#{dir}/#{name}")
      next if public_key_path.empty? || private_key_path.empty?

      begin
        return ::File.read(public_key_path[0]) unless public_key_path.empty?
      rescue => e
        raise "#{e.inspect} for softlayer_ssh_key object '#{name}'"
      end
    end
    nil
  end


  # ~/.softlayer/keys/name
  # ~/.softlayer/keys/name.pub
  def create_local_key(name)    
    %x(mkdir -p #{@@sshkeys_search_dirs[0]})

    key = OpenSSL::PKey::RSA.new 2048
    type = key.ssh_type
    data = [ key.to_blob ].pack('m0')
    openssh_format = "#{type} #{data}"

    open "#{@@sshkeys_search_dirs[0]}/#{name}", 'w' do |io| io.write key.to_pem end
    open "#{@@sshkeys_search_dirs[0]}/#{name}.pub", 'w' do |io| io.write openssh_format end
  end

  def delete_local_key(name)
    @@sshkeys_search_dirs.each do |dir|
       ::File.delete("#{dir}/#{name}.pub") if ::File.exists?("#{dir}/#{name}.pub")
       ::File.delete("#{dir}/#{name}") if ::File.exists?("#{dir}/#{name}")
    end
  end

  # Design for failure
  def create_softlayer_key(name)
     public_key_path = nil
     @@sshkeys_search_dirs.each do |dir|
       public_key_path = "#{dir}/#{name}.pub"
       if ::File.exists?("#{public_key_path}")
         break
       else
         public_key_path = nil
       end
     end
     
    raise "No local public key found to generate SSH key in SoftLayer" if public_key_path.nil?

     public_key   = ::File.read(public_key_path)
     key_service  = @@client[:Security_Ssh_Key]
     template_key = { "key" => public_key, "label" => "#{name}" }
     key_service.createObject template_key
  end

end