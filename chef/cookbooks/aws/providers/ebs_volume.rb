include Opscode::Aws::Ec2

# Support whyrun
def whyrun_supported?
  true
end

action :create do
  raise "Cannot create a volume with a specific id (EC2 chooses volume ids)" if new_resource.volume_id
  if new_resource.snapshot_id =~ /vol/
    new_resource.snapshot_id(find_snapshot_id(new_resource.snapshot_id, new_resource.most_recent_snapshot))
  end

  nvid = volume_id_in_node_data
  if nvid
    # volume id is registered in the node data, so check that the volume in fact exists in EC2
    vol = volume_by_id(nvid)
    exists = vol && vol[:aws_status] != "deleting"
    # TODO: determine whether this should be an error or just cause a new volume to be created. Currently erring on the side of failing loudly
    raise "Volume with id #{nvid} is registered with the node but does not exist in EC2. To clear this error, remove the ['aws']['ebs_volume']['#{new_resource.name}']['volume_id'] entry from this node's data." unless exists
  else
    # Determine if there is a volume that meets the resource's specifications and is attached to the current
    # instance in case a previous [:create, :attach] run created and attached a volume but for some reason was
    # not registered in the node data (e.g. an exception is thrown after the attach_volume request was accepted
    # by EC2, causing the node data to not be stored on the server)
    if new_resource.device && (attached_volume = currently_attached_volume(instance_id, new_resource.device))
      Chef::Log.debug("There is already a volume attached at device #{new_resource.device}")
      compatible = volume_compatible_with_resource_definition?(attached_volume)
      raise "Volume #{attached_volume[:aws_id]} attached at #{attached_volume[:aws_device]} but does not conform to this resource's specifications" unless compatible
      Chef::Log.debug("The volume matches the resource's definition, so the volume is assumed to be already created")
      converge_by("update the node data with volume id: #{attached_volume[:aws_id]}") do
        node.set['aws']['ebs_volume'][new_resource.name]['volume_id'] = attached_volume[:aws_id]
        node.save unless Chef::Config[:solo]
      end
    else
      # If not, create volume and register its id in the node data
      converge_by("create a volume with id=#{new_resource.snapshot_id} size=#{new_resource.size} availability_zone=#{new_resource.availability_zone} and update the node data with created volume's id") do
      nvid = create_volume(new_resource.snapshot_id,
                           new_resource.size,
                           new_resource.availability_zone,
                           new_resource.timeout,
                           new_resource.volume_type,
                           new_resource.piops)
        node.set['aws']['ebs_volume'][new_resource.name]['volume_id'] = nvid
        node.save unless Chef::Config[:solo]
      end
    end
  end
end

action :attach do
  # determine_volume returns a Hash, not a Mash, and the keys are
  # symbols, not strings.
  vol = determine_volume

  if vol[:aws_status] == "in-use"
    if vol[:aws_instance_id] != instance_id
      raise "Volume with id #{vol[:aws_id]} exists but is attached to instance #{vol[:aws_instance_id]}"
    else
      Chef::Log.debug("Volume is already attached")
    end
  else
    converge_by("attach the volume with aws_id=#{vol[:aws_id]} id=#{instance_id} device=#{new_resource.device} and update the node data with created volume's id") do
      # attach the volume and register its id in the node data
      attach_volume(vol[:aws_id], instance_id, new_resource.device, new_resource.timeout)
      # always use a symbol here, it is a Hash
      node.set['aws']['ebs_volume'][new_resource.name]['volume_id'] = vol[:aws_id]
      node.save unless Chef::Config[:solo]
    end
  end
end

action :detach do
  vol = determine_volume
  converge_by("detach volume with id: #{vol[:aws_id]}") do
    detach_volume(vol[:aws_id], new_resource.timeout)
  end
end

action :snapshot do
  vol = determine_volume
  converge_by("would create a snapshot for volume: #{vol[:aws_id]}") do
    snapshot = ec2.create_snapshot(vol[:aws_id],new_resource.description)
    Chef::Log.info("Created snapshot of #{vol[:aws_id]} as #{snapshot[:aws_id]}")
  end
end

action :prune do
  vol = determine_volume
  old_snapshots = Array.new
  Chef::Log.info "Checking for old snapshots"
  ec2.describe_snapshots.sort { |a,b| b[:aws_started_at] <=> a[:aws_started_at] }.each do |snapshot|
    if snapshot[:aws_volume_id] == vol[:aws_id]
      Chef::Log.info "Found old snapshot #{snapshot[:aws_id]} (#{snapshot[:aws_volume_id]}) #{snapshot[:aws_started_at]}"
      old_snapshots << snapshot
    end
  end
  if old_snapshots.length > new_resource.snapshots_to_keep
    old_snapshots[new_resource.snapshots_to_keep, old_snapshots.length].each do |die|
      converge_by("delete snapshot with id: #{die[:aws_id]}") do
        Chef::Log.info "Deleting old snapshot #{die[:aws_id]}"
        ec2.delete_snapshot(die[:aws_id])
      end
    end
  end
end

private

def volume_id_in_node_data
  begin
    node['aws']['ebs_volume'][new_resource.name]['volume_id']
  rescue NoMethodError => e
    nil
  end
end

# Pulls the volume id from the volume_id attribute or the node data and verifies that the volume actually exists
def determine_volume
  vol = currently_attached_volume(instance_id, new_resource.device)
  vol_id = new_resource.volume_id || volume_id_in_node_data || ( vol ? vol[:aws_id] : nil )
  raise "volume_id attribute not set and no volume id is set in the node data for this resource (which is populated by action :create) and no volume is attached at the device" unless vol_id

  # check that volume exists
  vol = volume_by_id(vol_id)
  raise "No volume with id #{vol_id} exists" unless vol

  vol
end

# Retrieves information for a volume
def volume_by_id(volume_id)
  ec2.describe_volumes.find{|v| v[:aws_id] == volume_id}
end

# Returns the volume that's attached to the instance at the given device or nil if none matches
def currently_attached_volume(instance_id, device)
  ec2.describe_volumes.find{|v| v[:aws_instance_id] == instance_id && v[:aws_device] == device}
end

# Returns true if the given volume meets the resource's attributes
def volume_compatible_with_resource_definition?(volume)
  if new_resource.snapshot_id =~ /vol/
    new_resource.snapshot_id(find_snapshot_id(new_resource.snapshot_id, new_resource.most_recent_snapshot))
  end
  (new_resource.size.nil? || new_resource.size == volume[:aws_size]) &&
  (new_resource.availability_zone.nil? || new_resource.availability_zone == volume[:zone]) &&
  (new_resource.snapshot_id.nil? || new_resource.snapshot_id == volume[:snapshot_id])
end

# Creates a volume according to specifications and blocks until done (or times out)
def create_volume(snapshot_id, size, availability_zone, timeout, volume_type, piops)
  availability_zone ||= instance_availability_zone

  # Sanity checks so we don't shoot ourselves.
  raise "Invalid volume type: #{volume_type}" unless ['standard', 'io1'].include?(volume_type)

  # PIOPs requested. Must specify an iops param and probably won't be "low".
  if volume_type == 'io1'
    raise 'IOPS value not specified.' unless piops > 100
  end

  # Shouldn't see non-zero piops param without appropriate type.
  if piops > 0
    raise 'IOPS param without piops volume type.' unless volume_type == 'io1'
  end

  create_volume_opts = { :volume_type => volume_type }
  # TODO: this may have to be casted to a string.  rightaws vs aws doc discrepancy.
  create_volume_opts[:iops] = piops if volume_type == 'io1'

  nv = ec2.create_volume(snapshot_id, size, availability_zone, create_volume_opts)
  Chef::Log.debug("Created new volume #{nv[:aws_id]}#{snapshot_id ? " based on #{snapshot_id}" : ""}")

  # block until created
  begin
    Timeout::timeout(timeout) do
      while true
        vol = volume_by_id(nv[:aws_id])
        if vol && vol[:aws_status] != "deleting"
          if ["in-use", "available"].include?(vol[:aws_status])
            Chef::Log.info("Volume #{nv[:aws_id]} is available")
            break
          else
            Chef::Log.debug("Volume is #{vol[:aws_status]}")
          end
          sleep 3
        else
          raise "Volume #{nv[:aws_id]} no longer exists"
        end
      end
    end
  rescue Timeout::Error
    raise "Timed out waiting for volume creation after #{timeout} seconds"
  end

  nv[:aws_id]
end

# Attaches the volume and blocks until done (or times out)
def attach_volume(volume_id, instance_id, device, timeout)
  Chef::Log.debug("Attaching #{volume_id} as #{device}")
  ec2.attach_volume(volume_id, instance_id, device)

  # block until attached
  begin
    Timeout::timeout(timeout) do
      while true
        vol = volume_by_id(volume_id)
        if vol && vol[:aws_status] != "deleting"
          if vol[:aws_attachment_status] == "attached"
            if vol[:aws_instance_id] == instance_id
              Chef::Log.info("Volume #{volume_id} is attached to #{instance_id}")
              break
            else
              raise "Volume is attached to instance #{vol[:aws_instance_id]} instead of #{instance_id}"
            end
          else
            Chef::Log.debug("Volume is #{vol[:aws_status]}")
          end
          sleep 3
        else
          raise "Volume #{volume_id} no longer exists"
        end
      end
    end
  rescue Timeout::Error
    raise "Timed out waiting for volume attachment after #{timeout} seconds"
  end
end

# Detaches the volume and blocks until done (or times out)
def detach_volume(volume_id, timeout)
  vol = volume_by_id(volume_id)
  if vol[:aws_instance_id] != instance_id
    Chef::Log.debug("EBS Volume #{volume_id} is not attached to this instance (attached to #{vol[:aws_instance_id]}). Skipping...")
    return
  end
  Chef::Log.debug("Detaching #{volume_id}")
  orig_instance_id = vol[:aws_instance_id]
  ec2.detach_volume(volume_id)

  # block until detached
  begin
    Timeout::timeout(timeout) do
      while true
        vol = volume_by_id(volume_id)
        if vol && vol[:aws_status] != "deleting"
          if vol[:aws_instance_id] != orig_instance_id
            Chef::Log.info("Volume detached from #{orig_instance_id}")
            break
          else
            Chef::Log.debug("Volume: #{vol.inspect}")
          end
        else
          Chef::Log.debug("Volume #{volume_id} no longer exists")
          break
        end
        sleep 3
      end
    end
  rescue Timeout::Error
    raise "Timed out waiting for volume detachment after #{timeout} seconds"
  end
end


