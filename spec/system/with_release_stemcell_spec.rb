require 'system/spec_helper'

describe 'with release and stemcell and subsequent deployments' do
  before(:all) do
    @requirements.requirement(@requirements.release)
    @requirements.requirement(@requirements.stemcell)
    load_deployment_spec
  end

  context 'with no ephemeral disk', root_partition: true do
    before do
      reload_deployment_spec
      use_static_ip
      use_vip
      use_instance_group('batlight')
      use_jobs(%w[batlight])

      use_flavor_with_no_ephemeral_disk

      @requirements.requirement(deployment, @spec)
    end

    after do |example|
      check_for_failure(@spec_state, example)
      @requirements.cleanup(deployment)
    end

    it 'creates ephemeral and swap partitions on the root device if no ephemeral disk', ssh: true, core: true do
      setting_value = agent_config().
        fetch('Platform', {}).
        fetch('Linux', {}).
        fetch('CreatePartitionIfNoEphemeralDisk', false)

      skip 'root disk ephemeral partition requires a stemcell with CreatePartitionIfNoEphemeralDisk enabled' unless setting_value

      # expect ephemeral mount point to be a mounted partition on the root disk
      expect(mounts()).to include(hash_including('path' => '/var/vcap/data'))

      # expect swap to be a mounted partition on the root disk
      expect(swaps()).to include(hash_including('type' => 'partition'))
    end

    def agent_config
      output = bosh_ssh('batlight', 0, 'sudo cat /var/vcap/bosh/agent.json', deployment: deployment.name, result: true, column: 'stdout').output
      JSON.parse(output)
    end

    def mounts
      output = bosh_ssh('batlight', 0, 'mount', deployment: deployment.name, result: true, column: 'stdout').output
      output.lines.map do |line|
        matches = /(?<point>.*) on (?<path>.*) type (?<type>.*) \((?<options>.*)\)/.match(line)
        next if matches.nil?
        matchdata_to_h(matches)
      end.compact
    end

    def swaps
      output = bosh_ssh('batlight', 0, 'PATH=$PATH:/usr/sbin swapon -s', deployment: deployment.name, result: true, column: 'stdout').output
      output.lines.to_a[1..-1].map do |line|
        matches = /(?<point>.+)\s+(?<type>.+)\s+(?<size>.+)\s+(?<used>.+)\s+(?<priority>.+)/.match(line)
        next if matches.nil?
        matchdata_to_h(matches)
      end.compact
    end

    def matchdata_to_h(matchdata)
      Hash[matchdata.names.zip(matchdata.captures)]
    end
  end
  
  describe 'general stemcell configuration' do
    before(:all) do
      reload_deployment_spec
      # using password 'foobar'
      use_password('$6$tHAu4zCTso$pAQok0MTHP4newel7KMhTzMI4tQrAWwJ.X./fFAKjbWkCb5sAaavygXAspIGWn8qVD8FeT.Z/XN4dvqKzLHhl0')
      use_static_ip
      use_vip
      @jobs = %w[
        /var/vcap/packages/batlight/bin/batlight
        /var/vcap/packages/batarang/bin/batarang
      ]
      use_instance_group('colocated')
      use_jobs(%w[batarang batlight])

      @requirements.requirement(deployment, @spec)
    end

    after(:all) do
      @requirements.cleanup(deployment)
    end

    # this test case will not test password for vcap correctly after changing to bosh_ssh.
    # even with ssh, if we set private_key in our ssh_option, we still failing testing password.
    it 'should set vcap password', ssh: true, core: true do
      expect(bosh_ssh('colocated', 0, 'sudo whoami', deployment: deployment.name).output).to match /root/
    end

    it 'should not change the deployment on a noop', core: true do
      bosh("deploy #{deployment.to_path}", deployment: deployment.name)
      events(get_most_recent_task_id).each do |event|
        if event['stage']
          expect(event['stage']).to_not match(/^Updating/)
        end
      end
    end

    it 'should use job colocation', ssh: true, core: true do
      @jobs.each do |job|
        ssh_command = "ps -ef | grep #{job} | grep -v grep"
        expect(bosh_ssh('colocated', 0, ssh_command, deployment: deployment.name).output).to match /#{job}/
      end
    end

    it 'should have network access to the vm using the manual static ip', manual_networking: true, ssh: true do
      instance = wait_for_process_state('colocated', '0', 'running')
      expect(instance).to_not be_nil
      expect(static_ip).to_not be_nil
      expect(bosh_ssh('colocated', 0, 'hostname', deployment: deployment.name).output).to match /#{instance[:agent_id]}/
    end

    it 'should have network access to the vm using the vip', vip_networking: true, ssh: true do
      unless warden? 
        instance = wait_for_process_state('colocated', '0', 'running')
        expect(instance).to_not be_nil
        expect(vip).to_not be_nil
        expect(bosh_ssh('colocated', 0, 'hostname', deployment: deployment.name).output).to match /#{instance[:agent_id]}/
      end
    end
  end
end
