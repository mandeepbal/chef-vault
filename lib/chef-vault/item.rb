# Author:: Kevin Moser <kevin.moser@nordstrom.com>
# Copyright:: Copyright 2013-15, Nordstrom, Inc.
# License:: Apache License, Version 2.0

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

#     http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'securerandom'

class ChefVault
  class Item < Chef::DataBagItem
    attr_accessor :keys
    attr_accessor :encrypted_data_bag_item

    def initialize(vault, name)
      super() # Don't pass parameters
      @data_bag = vault
      @raw_data["id"] = name
      @keys = ChefVault::ItemKeys.new(vault, "#{name}_keys")
      @secret = generate_secret
      @encrypted = false
    end

    def load_keys(vault, keys)
      @keys = ChefVault::ItemKeys.load(vault, keys)
      @secret = secret
    end

    def clients(search=nil, action=:add)
      if search
        results_returned = false

        query = Chef::Search::Query.new
        query.search(:node, search)[0].each do |node|
          results_returned = true

          case action
          when :add
            begin
              keys.add(load_client(node.name), @secret, "clients")
            rescue ChefVault::Exceptions::ClientNotFound
              $stderr.puts "node '#{node.name}' has no private key; skipping"
            end
          when :delete
            keys.delete(node.name, "clients")
          else
            raise ChefVault::Exceptions::KeysActionNotValid,
              "#{action} is not a valid action"
          end
        end

        unless results_returned
          puts "WARNING: No clients were returned from search, you may not have "\
            "got what you expected!!"
        end
      else
        keys.clients
      end
    end

    def search(search_query=nil)
      if search_query
        keys.search_query(search_query)
      else
        keys.search_query
      end
    end

    def admins(admins=nil, action=:add)
      if admins
        admins.split(",").each do |admin|
          admin.strip!
          case action
          when :add
            keys.add(load_admin(admin), @secret, "admins")
          when :delete
            keys.delete(admin, "admins")
          else
            raise ChefVault::Exceptions::KeysActionNotValid,
              "#{action} is not a valid action"
          end
        end
      else
        keys.admins
      end
    end

    def remove(key)
      @raw_data.delete(key)
    end

    def secret
      if @keys.include?(Chef::Config[:node_name])
        private_key = OpenSSL::PKey::RSA.new(open(Chef::Config[:client_key]).read())
        begin
          private_key.private_decrypt(Base64.decode64(@keys[Chef::Config[:node_name]]))
        rescue OpenSSL::PKey::RSAError
          raise ChefVault::Exceptions::SecretDecryption,
            "#{data_bag}/#{id} is encrypted for you, but your private key failed to decrypt the contents.  "\
            "(if you regenerated your client key, have an administrator of the vault run 'knife vault refresh')"
        end
      else
        raise ChefVault::Exceptions::SecretDecryption,
          "#{data_bag}/#{id} is not encrypted with your public key.  "\
          "Contact an administrator of the vault item to encrypt for you!"
      end
    end

    def rotate_keys!(clean_unknown_clients = false)
      @secret = generate_secret

      unless clients.empty?
        # a bit of a misnomer; this doesn't remove unknown
        # admins, just clients which are nodes
        remove_unknown_nodes if clean_unknown_clients
        # re-encrypt the new shared secret for all remaining clients
        clients.each do |client|
          clients("name:#{client}")
        end
      end

      unless admins.empty?
        # re-encrypt the new shared secret for all admins
        admins.each do |admin|
          admins(admin)
        end
      end

      save
      reload_raw_data
    end

    def generate_secret(key_size=32)
      # Defaults to 32 bytes, as this is the size that a Chef
      # Encrypted Data Bag Item will digest all secrets down to anyway
      SecureRandom.random_bytes(key_size)
    end

    def []=(key, value)
      reload_raw_data if @encrypted
      super
    end

    def [](key)
      reload_raw_data if @encrypted
      super
    end

    def save(item_id=@raw_data['id'])
      # validate the format of the id before attempting to save
      validate_id!(item_id)

      # save the keys first, raising an error if no keys were defined
      if keys.admins.empty? && keys.clients.empty?
        raise ChefVault::Exceptions::NoKeysDefined,
          "No keys defined for #{item_id}"
      end

      keys.save

      # Make sure the item is encrypted before saving
      encrypt! unless @encrypted

      # Now save the encrypted data
      if Chef::Config[:solo]
        data_bag_path = File.join(Chef::Config[:data_bag_path],
                                  data_bag)
        data_bag_item_path = File.join(data_bag_path, item_id)

        FileUtils.mkdir(data_bag_path) unless File.exist?(data_bag_path)
        File.open("#{data_bag_item_path}.json", 'w') do |file|
          file.write(JSON.pretty_generate(raw_data))
        end

        raw_data
      else
        begin
          Chef::DataBag.load(data_bag)
        rescue Net::HTTPServerException => http_error
          if http_error.response.code == "404"
            chef_data_bag = Chef::DataBag.new
            chef_data_bag.name data_bag
            chef_data_bag.create
          end
        end

        super
      end
    end

    def to_json(*a)
      json = super
      json.gsub(self.class.name, self.class.superclass.name)
    end

    def destroy
      keys.destroy

      if Chef::Config[:solo]
        data_bag_path = File.join(Chef::Config[:data_bag_path],
                                  data_bag)
        data_bag_item_path = File.join(data_bag_path, @raw_data["id"])

        FileUtils.rm("#{data_bag_item_path}.json")

        nil
      else
        super(data_bag, id)
      end
    end

    def self.load(vault, name)
      item = new(vault, name)
      item.load_keys(vault, "#{name}_keys")

      begin
        item.raw_data =
          Chef::EncryptedDataBagItem.load(vault, name, item.secret).to_hash
      rescue Net::HTTPServerException => http_error
        if http_error.response.code == "404"
          raise ChefVault::Exceptions::ItemNotFound,
            "#{vault}/#{name} could not be found"
        else
          raise http_error
        end
      rescue Chef::Exceptions::ValidationFailed
        raise ChefVault::Exceptions::ItemNotFound,
          "#{vault}/#{name} could not be found"
      end

      item
    end

    private

    def encrypt!
      @raw_data = Chef::EncryptedDataBagItem.encrypt_data_bag_item(self, @secret)
      @encrypted = true
    end

    def reload_raw_data
      @raw_data =
        Chef::EncryptedDataBagItem.load(@data_bag, @raw_data["id"], secret).to_hash
      @encrypted = false

      @raw_data
    end

    def load_admin(admin)
      begin
        admin = ChefVault::ChefPatch::User.load(admin)
      rescue Net::HTTPServerException => http_error
        if http_error.response.code == "404"
          begin
            puts "WARNING: #{admin} not found in users, trying clients."
            admin = load_client(admin)
          rescue ChefVault::Exceptions::ClientNotFound
            raise ChefVault::Exceptions::AdminNotFound,
              "FATAL: Could not find #{admin} in users or clients!"
          end
        else
          raise http_error
        end
      end

      admin
    end

    def load_client(client)
      begin
        client = ChefVault::ChefPatch::ApiClient.load(client)
      rescue Net::HTTPServerException => http_error
        if http_error.response.code == "404"
          raise ChefVault::Exceptions::ClientNotFound,
            "#{client} is not a valid chef client and/or node"
        else
          raise http_error
        end
      end

      client
    end

    # removes unknown nodes by performing a node search
    # for each of the existing nodclientses.  If the search
    # returns nothing or the client cannot be loaded, then
    # we remove that client from the vault
    # @return [void]
    def remove_unknown_nodes
      # build a list of clients to remove so we don't
      # mutate the clients while iterating over search results
      clients_to_remove = []
      clients.each do |nodename|
        clients_to_remove.push(nodename) unless node_exists?(nodename)
      end
      # now delete any flagged clients from the keys data bag
      clients_to_remove.each do |client|
        puts "Removing unknown client '#{client}'"
        keys.delete(client, "clients")
      end
    end

    # checks if a node exists on the Chef server by performing
    # a search against the node index.  If the search returns no
    # results, the node does not exist.  If it does return results,
    # check if there is a matching client
    # @param nodename [String] the name of the node
    # @return [Boolean] whether the node exists or not
    def node_exists?(nodename)
      # the node does not exist if a search for the node with that
      # name returns no results
      query = Chef::Search::Query.new
      numresults = query.search(:node, "name:#{nodename}")[2]
      return false unless numresults > 0
      # if the node search does return results, predicate node
      # existence on the existence of a like-named client
      client_exists?(nodename)
    end

    # checks if a client exists on the Chef server.  If we get back
    # a 404, the client does not exist.  Any other HTTP errors are
    # re-raised.  Otherwise, the client exists
    # @param clientname [String] the name of the client
    # @return [Boolean] whether the client exists or not
    def client_exists?(clientname)
      begin
        ChefVault::ChefPatch::ApiClient.load(clientname)
      rescue Net::HTTPServerException => http_error
        return false if http_error.response.code == "404"
        raise http_error
      end
      true
    end
  end
end
