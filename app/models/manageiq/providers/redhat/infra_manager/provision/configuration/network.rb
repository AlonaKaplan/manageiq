module ManageIQ::Providers::Redhat::InfraManager::Provision::Configuration::Network
  def configure_network_adapters
    configure_dialog_nic
    requested_vnics = options[:networks]

    if requested_vnics.nil?
      _log.info "NIC settings will be inherited from the template."
      return
    end

    if destination.ext_management_system.supports_update_vnic_profile?
      configure_v4_vnics(requested_vnics)
    else
      configure_v3_vnics(requested_vnics)
    end
  end

  # TODO: Move this into EMS Refresh
  def get_mac_address_of_nic_on_requested_vlan
    network = find_network_in_cluster(get_option(:vlan))
    return nil if network.nil?

    nic = find_nic_on_network(network)
    return nil if nic.nil?

    nic[:mac][:address]
  end

  private

  def destination_vnics
    # Nics are not always ordered in the XML response
    @destination_vnics ||= get_provider_destination.nics.sort_by { |n| n[:name] }
  end

  def find_network_in_cluster(network_name)
    network = source.with_provider_connection do |rhevm|
      Ovirt::Cluster.find_by_href(rhevm, dest_cluster.ems_ref).try(:find_network_by_name, network_name)
    end

    _log.warn "Cannot find network name=#{network_name}" if network.nil?
    network
  end

  def find_nic_on_network(network)
    nic = get_provider_destination.nics.detect { |n| n[:network][:id] == network[:id] }

    _log.warn "Cannot find NIC with network id=#{network[:id].inspect}" if nic.nil?
    nic
  end

  def configure_dialog_nic
    vlan = get_option(:vlan)
    return if vlan.blank?
    options[:networks] ||= []
    options[:networks][0] ||= begin
      _log.info("vlan: #{vlan.inspect}")
      {:network => vlan, :mac_address => get_option_last(:mac_address)}
    end
  end

  def createNewVnicName(idx)
    "nic#{idx + 1}"
  end

  def configure_v3_vnics(requested_vnics)
    requested_vnics.stretch!(destination_vnics).each_with_index do |requested_vnic, idx|
      if requested_vnic.nil?
        # Remove any unneeded vm nics
        destination_vnics[idx].destroy
      else
        configure_v3_vnic(createNewVnicName(idx), requested_vnic, destination_vnics[idx])
      end
    end
  end

  def configure_v3_vnic(name, network_hash, vnic)
    network = find_network_in_cluster(network_hash[:network])

    raise MiqException::MiqProvisionError, "Unable to find specified network: <#{network_hash[:network]}>" if network.nil?

    options = {
        :name => name,
        :interface => network_hash[:interface],
        :network_id => network[:id],
        :mac_address => network_hash[:mac_address],
    }.delete_blanks

    _log.info("with options: <#{options.inspect}>")

    vnic.nil? ? get_provider_destination.create_nic(options) : vnic.apply_options!(options)
  end

  def configure_v4_vnics(requested_vnics)
    destination.ext_management_system.with_provider_connection(:version => 4) do |connection|
      nics_service = connection.system_service.vms_service.vm_service(destination.uid_ems).nics_service

      requested_vnics.stretch!(destination_vnics).each_with_index do |requested_vnic, idx|
        if requested_vnic.nil?
          nics_service.nic_service(destination_vnics[idx][:id]).remove
        else
          configure_v4_vnic(requested_vnic, createNewVnicName(idx), destination_vnics[idx], nics_service)
        end
      end
    end
  end

  def configure_v4_vnic(network_hash, name, vnic, nics_service)
    profile_id = network_hash[:network]
    if profile_id == '<Empty>'
      profile_id = nil
    end

    options = {
        :name => name,
        :vnic_profile => {id: profile_id},
        :mac_address => network_hash[:mac_address],
    }.delete_blanks

    if vnic.nil?
      nics_service.add(OvirtSDK4::Nic.new(options))
    else
      nics_service.nic_service(vnic[:id]).update(options)
    end

  end

end