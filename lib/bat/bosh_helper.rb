require 'httpclient'
require 'json'
require 'net/ssh'
require 'zlib'
require 'archive/tar/minitar'
require 'tempfile'
require 'common/exec'

module Bat
  module BoshHelper
    include Archive::Tar

    def bosh(*args, &blk)
      @bosh_runner.bosh(*args, &blk)
    end

    def bosh_safe(*args, &blk)
      @bosh_runner.bosh_safe(*args, &blk)
    end

    def ssh_options
      {
        private_key: @env.private_key
      }
    end

    def aws?
      @env.bat_infrastructure == 'aws'
    end

    def openstack?
      @env.bat_infrastructure == 'openstack'
    end

    def warden?
      @env.bat_infrastructure == 'warden'
    end

    def vsphere?
      @env.bat_infrastructure == 'vsphere'
    end

    def persistent_disk(job, index, options)
      get_disks(job, index, options).each do |_, disk|
        return disk[:blocks] if disk[:mountpoint] == '/var/vcap/store'
      end
      raise 'Could not find persistent disk size'
    end

    def ssh(host, user, command, options = {})
      options = options.dup
      output = nil
      @logger.info("--> ssh: #{user}@#{host} #{command.inspect}")

      private_key = options.delete(:private_key)
      options[:user_known_hosts_file] = %w[/dev/null]
      options[:keys] = [private_key] unless private_key.nil?

      raise 'Need to set ssh :keys, or :private_key' if options[:keys].nil?

      @logger.info("--> ssh options: #{options.inspect}")
      Net::SSH.start(host, user, options) do |ssh|
        output = ssh.exec!(command).to_s
      end

      @logger.info("--> ssh output: #{output.inspect}")
      output
    end

    def bosh_ssh(job, index, command, options = {})
      options[:json] = false
      column = options.delete(:column)

      bosh_ssh_options = ''
      bosh_ssh_options << '--results' if options.delete(:result)
      bosh_ssh_options << " --column=#{column}" if column
      bosh("ssh #{job}/#{index} -c '#{command}' #{bosh_ssh_options}", options)
    end

    def tarfile
      Dir.glob('*.tgz').first
    end

    def tar_contents(tgz, entries = false)
      list = []
      tar = Zlib::GzipReader.open(tgz)
      Minitar.open(tar).each do |entry|
        is_file = entry.file?
        entry = entry.name unless entries
        list << entry if is_file
      end
      list
    end

    def wait_for_process_state(name, index, state, wait_time_in_seconds=300)
      puts "Start waiting for instance #{name} to have process state #{state}"
      instance_in_state = nil
      10.times do
        instance = get_instance(name, index)
        if instance && instance['process_state'] =~ /#{state}/
          instance_in_state = instance
          break
        end
        sleep wait_time_in_seconds/10
      end
      if instance_in_state
        @logger.info("Finished waiting for instance #{name} have process state=#{state} instance=#{instance_in_state.inspect}")
        instance_in_state
      else
        raise Exception, "Instance is still not in expected process state: #{state}"
      end
    end

    def wait_for_instance_state(name, index, state, wait_time_in_seconds=300)
      puts "Start waiting for instance #{name} to have state #{state}"
      instance_in_state = nil
      10.times do
        instance = get_instance(name, index)
        if instance && instance['state'] =~ /#{state}/
          instance_in_state = instance
          break
        end
        sleep wait_time_in_seconds/10
      end
      if instance_in_state
        @logger.info("Finished waiting for instance #{name} have state=#{state} instance=#{instance_in_state.inspect}")
        instance_in_state
      else
        raise Exception, "Instance is still not in expected state: #{state}"
      end
    end

    private

    def get_instance(name, index)
      instance = get_instances.find do |i|
        i['instance'] =~ /#{name}\/[a-f0-9\-]{36}/ || i['instance'] =~ /#{name}\/#{index} \([a-f0-9\-]{36}\)/ && i['index'] == index
      end

      instance
    end

    def get_instances
      output = @bosh_runner.bosh('instances --details').output
      output_hash = JSON.parse(output)

      output_hash['Tables'][0]['Rows']
    end

    def get_disks(job, index, options)
      disks = {}
      df_cmd = 'df -x tmpfs -x devtmpfs -x debugfs -l | tail -n +2'

      options[:result] = true
      options[:json] = false
      options[:column] = 'stdout'

      df_output = bosh_ssh(job, index, df_cmd, options).output
      df_output.split("\n").each do |line|
        fields = line.split(/\s+/)
        disks[fields[0]] = {
          blocks: fields[1],
          used: fields[2],
          available: fields[3],
          percent: fields[4],
          mountpoint: fields[5]
        }
      end

      disks
    end

    def get_disk_cids(name, index)
      instance = get_instance(name, index)
      instance['disk_cids']
    end

    def get_agent_id(name, index)
      instance = get_instance(name, index)
      instance['agent_id']
    end

    def get_vm_cid(name, index)
      instance = get_instance(name, index)
      instance['vm_cid']
    end

    def unresponsive_agent_instance
      get_instances.find { |i| i['process_state'] == 'unresponsive agent' }
    end

    def unresponsive_agent_vm_cid
      unresponsive_agent_instance['vm_cid']
    end

    def vm_exists?(vm_cid)
      instance = get_instances.find { |i| i['vm_cid'] == vm_cid }
      return false if instance.nil?

      true
    end
  end
end
