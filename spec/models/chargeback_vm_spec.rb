describe ChargebackVm do
  shared_examples_for "ChargebackVm" do
    include Spec::Support::ChargebackHelper

    let(:admin) { FactoryGirl.create(:user_admin) }
    let(:base_options) do
      {:interval_size       => 2,
       :end_interval_offset => 0,
       :tag                 => '/managed/environment/prod',
       :ext_options         => {:tz => 'UTC'},
       :userid              => admin.userid}
    end
    let(:hourly_rate)               { 0.01 }
    let(:count_hourly_rate)         { 1.00 }
    let(:cpu_count)                 { 1.0 }
    let(:memory_available)          { 1000.0 }
    let(:vm_allocated_disk_storage) { 4.0 }
    let(:starting_date) { Time.parse('2012-09-01 23:59:59Z').utc }
    let(:ts) { starting_date.in_time_zone(Metric::Helper.get_time_zone(base_options[:ext_options])) }
    let(:report_run_time) { month_end }
    let(:month_beginning) { ts.beginning_of_month.utc }
    let(:month_end) { ts.end_of_month.utc }
    let(:hours_in_month) { Time.days_in_month(month_beginning.month, month_beginning.year) * 24 }
    let(:ems) { FactoryGirl.create(:ems_vmware) }

    let(:hourly_variable_tier_rate)       { {:variable_rate => hourly_rate.to_s} }
    let(:count_hourly_variable_tier_rate) { {:variable_rate => count_hourly_rate.to_s} }

    let(:detail_params) do
      {
          :chargeback_rate_detail_cpu_used           => {:tiers => [hourly_variable_tier_rate]},
          :chargeback_rate_detail_cpu_allocated      => {:tiers => [count_hourly_variable_tier_rate]},
          :chargeback_rate_detail_memory_allocated   => {:tiers => [hourly_variable_tier_rate]},
          :chargeback_rate_detail_memory_used        => {:tiers => [hourly_variable_tier_rate]},
          :chargeback_rate_detail_disk_io_used       => {:tiers => [hourly_variable_tier_rate]},
          :chargeback_rate_detail_net_io_used        => {:tiers => [hourly_variable_tier_rate]},
          :chargeback_rate_detail_storage_used       => {:tiers => [count_hourly_variable_tier_rate]},
          :chargeback_rate_detail_storage_allocated  => {:tiers => [count_hourly_variable_tier_rate]},
          :chargeback_rate_detail_fixed_compute_cost => {:tiers => [hourly_variable_tier_rate]},
          :chargeback_rate_detail_metering_used      => {:tiers => [count_hourly_variable_tier_rate]}
      }
    end

    let!(:chargeback_rate) do
      FactoryGirl.create(:chargeback_rate, :detail_params => detail_params)
    end

    let(:metric_rollup_params) do
      {
          :tag_names             => "environment/prod",
          :parent_host_id        => @host1.id,
          :parent_ems_cluster_id => @ems_cluster.id,
          :parent_ems_id         => ems.id,
          :parent_storage_id     => @storage.id,
      }
    end

    before do
      # TODO: remove metering columns form specs
      described_class.set_columns_hash(:metering_used_metric => :integer, :metering_used_cost => :float)

      MiqRegion.seed
      ChargebackRateDetailMeasure.seed
      ChargeableField.seed
      ManageIQ::Showback::InputMeasure.seed
      MiqEnterprise.seed

      EvmSpecHelper.create_guid_miq_server_zone
      cat = FactoryGirl.create(:classification, :description => "Environment", :name => "environment", :single_value => true, :show => true)
      c = FactoryGirl.create(:classification, :name => "prod", :description => "Production", :parent_id => cat.id)
      @tag = Tag.find_by(:name => "/managed/environment/prod")

      temp = {:cb_rate => chargeback_rate, :tag => [c, "vm"]}
      ChargebackRate.set_assignments(:compute, [temp])

      Timecop.travel(report_run_time)
    end

    after do
      Timecop.return
    end

    context 'with metric rollups' do
      before do
        @vm1 = FactoryGirl.create(:vm_vmware, :name => "test_vm", :evm_owner => admin, :ems_ref => "ems_ref",
                                  :created_on => month_beginning)
        @vm1.tag_with(@tag.name, :ns => '*')

        @host1   = FactoryGirl.create(:host, :hardware => FactoryGirl.create(:hardware, :memory_mb => 8124, :cpu_total_cores => 1, :cpu_speed => 9576), :vms => [@vm1])
        @storage = FactoryGirl.create(:storage_target_vmware)
        @host1.storages << @storage

        @ems_cluster = FactoryGirl.create(:ems_cluster, :ext_management_system => ems)
        @ems_cluster.hosts << @host1
      end

      let(:report_static_fields) { %w(vm_name) }

      it "uses static fields" do
        expect(described_class.report_static_cols).to match_array(report_static_fields)
      end

      it "succeeds without a userid" do
        options = base_options.except(:userid)
        expect { ChargebackVm.build_results_for_report_ChargebackVm(options) }.not_to raise_error
      end

      context "by service" do
        let(:options) { base_options.merge(:interval => 'monthly', :interval_size => 4, :service_id => @service.id) }
        before do
          @service = FactoryGirl.create(:service)
          @service << @vm1
          @service.save

          @vm2 = FactoryGirl.create(:vm_vmware, :name => "test_vm 2", :evm_owner => admin, :created_on => month_beginning)

          add_metric_rollups_for([@vm1, @vm2], month_beginning...month_end, 12.hours, metric_rollup_params)
        end

        it "only includes VMs belonging to service in results" do
          result = described_class.build_results_for_report_ChargebackVm(options)
          expect(result).not_to be_nil
          expect(result.first.all? { |r| r.vm_name == "test_vm" })
        end
      end

      context "Daily" do
        let(:hours_in_day) { 24 }
        let(:options) { base_options.merge(:interval => 'daily') }

        let(:start_time)  { report_run_time - 17.hours }
        let(:finish_time) { report_run_time - 14.hours }

        let(:cloud_volume) { FactoryGirl.create(:cloud_volume_openstack) }

        it 'contains also columns with sub_metric(from cloud_volume)' do
          skip('this feature needs to be added to new chargeback rating') if Settings.new_chargeback

          cloud_volume_type_chargeback_colums = []
          %w(metric cost).each do |key|
            cloud_volume_type_chargeback_colums << "storage_allocated_#{cloud_volume.volume_type}_#{key}"
          end

          described_class.refresh_dynamic_metric_columns

          expect(cloud_volume_type_chargeback_colums & described_class.attribute_names).to match_array(cloud_volume_type_chargeback_colums)
        end

        before do
          add_metric_rollups_for(@vm1, start_time...finish_time, 1.hour, metric_rollup_params)
        end

        context 'with cloud volume types' do
          let!(:cloud_volume_sdd) { FactoryGirl.create(:cloud_volume_openstack, :volume_type => 'sdd') }
          let!(:cloud_volume_hdd) { FactoryGirl.create(:cloud_volume_openstack, :volume_type => 'hdd') }
          let(:state_data) do
            {
              :allocated_disk_types => {
                'sdd' => 3.gigabytes,
                'hdd' => 1.gigabytes,
              },
            }
          end

          before do
            # create vim performance state
            allocated_storage_rate_detail = chargeback_rate.chargeback_rate_details.detect { |x| x.chargeable_field.metric == 'derived_vm_allocated_disk_storage' }
            CloudVolume.all.each do |cv|
              new_rate_detail = allocated_storage_rate_detail.dup
              new_rate_detail.sub_metric = cv.volume_type
              new_rate_detail.chargeback_tiers = allocated_storage_rate_detail.chargeback_tiers.map(&:dup)
              new_rate_detail.save
              chargeback_rate.chargeback_rate_details << new_rate_detail
            end

            chargeback_rate.save
            add_vim_performance_state_for(@vm1, start_time...finish_time, 1.hour, state_data)
          end

          it 'charges sub metrics as cloud volume types' do
            skip('this feature needs to be added to new chargeback rating') if Settings.new_chargeback

            expect(subject.storage_allocated_sdd_metric).to eq(3.gigabytes)
            expect(subject.storage_allocated_sdd_cost).to eq(state_data[:allocated_disk_types]['sdd'] / 1.gigabytes * count_hourly_rate * hours_in_day)

            expect(subject.storage_allocated_hdd_metric).to eq(1.gigabytes)
            expect(subject.storage_allocated_hdd_cost).to eq(state_data[:allocated_disk_types]['hdd'] / 1.gigabytes * count_hourly_rate * hours_in_day)
          end

          it 'shows rates' do
            skip('this feature needs to be added to new chargeback rating') if Settings.new_chargeback
            expect(subject.storage_allocated_sdd_rate).to eq("0.0/1.0")
            expect(subject.storage_allocated_hdd_rate).to eq("0.0/1.0")
          end

          it "doesn't return removed cloud volume types fields" do
            described_class.refresh_dynamic_metric_columns

            fields = described_class.attribute_names
            cloud_volume_hdd_field = "storage_allocated_#{cloud_volume_hdd.volume_type}_metric"
            expect(fields).to include(cloud_volume_hdd_field)

            cloud_volume_hdd.destroy

            described_class.refresh_dynamic_metric_columns
            fields = described_class.attribute_names
            expect(fields).not_to include(cloud_volume_hdd_field)
          end
        end

        subject { ChargebackVm.build_results_for_report_ChargebackVm(options).first.first }

        context 'when the Vm resource of a consumption is destroyed' do
          let(:hours_in_day) { (finish_time.end_of_day - start_time) / 1.hour }

          before do
            @vm1.destroy
          end

          it "calculates allocated cpu cost and metric values" do
            skip('this case needs to be fixed in new chargeback') if Settings.new_chargeback

            expect(subject.cpu_allocated_metric).to eq(cpu_count)
            expect(subject.cpu_allocated_cost).to eq(cpu_count * count_hourly_rate * hours_in_day)
            expect(subject.cpu_cost).to eq(subject.cpu_allocated_cost + subject.cpu_used_cost)
          end
        end

        context 'when first metric rollup has tag_names=nil' do
          before do
            options[:tag] = nil
            options[:entity_id] = @vm1.id
            @vm1.metric_rollups.first.update_attributes(:tag_names => nil)
          end

          it "cpu" do
            expect(subject.cpu_allocated_metric).to eq(cpu_count)
            used_metric = used_average_for(:cpu_usagemhz_rate_average, hours_in_day, @vm1)
            expect(subject.cpu_used_metric).to eq(used_metric)

            expect(subject.cpu_allocated_cost).to eq(cpu_count * count_hourly_rate * hours_in_day)
            expect(subject.cpu_used_cost).to eq(used_metric * hourly_rate * hours_in_day)
            expect(subject.cpu_cost).to eq(subject.cpu_allocated_cost + subject.cpu_used_cost)
          end
        end

        it "cpu" do
          expect(subject.cpu_allocated_metric).to eq(cpu_count)
          used_metric = used_average_for(:cpu_usagemhz_rate_average, hours_in_day, @vm1)
          expect(subject.cpu_used_metric).to eq(used_metric)

          expect(subject.cpu_allocated_cost).to eq(cpu_count * count_hourly_rate * hours_in_day)
          expect(subject.cpu_used_cost).to eq(used_metric * hourly_rate * hours_in_day)
          expect(subject.cpu_cost).to eq(subject.cpu_allocated_cost + subject.cpu_used_cost)
        end

        it "reports Vm Guid" do
          expect(subject.vm_guid).to eq(@vm1.guid)
        end

        it "cpu_vm_and_cpu_container_project" do
          expect(subject.cpu_allocated_metric).to eq(cpu_count)
          used_metric = used_average_for(:cpu_usagemhz_rate_average, hours_in_day, @vm1)
          expect(subject.cpu_used_metric).to eq(used_metric)

          expect(subject.cpu_allocated_cost).to eq(cpu_count * count_hourly_rate * hours_in_day)
          expect(subject.cpu_used_cost).to eq(used_metric * hourly_rate * hours_in_day)
          expect(subject.cpu_cost).to eq(subject.cpu_allocated_cost + subject.cpu_used_cost)
        end

        it "memory" do
          expect(subject.memory_allocated_metric).to eq(memory_available)
          used_metric = used_average_for(:derived_memory_used, hours_in_day, @vm1)
          expect(subject.memory_used_metric).to eq(used_metric)

          expect(subject.memory_allocated_cost).to eq(memory_available * hourly_rate * hours_in_day)
          expect(subject.memory_used_cost).to eq(used_metric * hourly_rate * hours_in_day)
          expect(subject.memory_cost).to eq(subject.memory_allocated_cost + subject.memory_used_cost)
        end

        it "disk io" do
          used_metric = used_average_for(:disk_usage_rate_average, hours_in_day, @vm1)
          expect(subject.disk_io_used_metric).to eq(used_metric)
          expect(subject.disk_io_used_cost).to be_within(0.01).of(used_metric * hourly_rate * hours_in_day)
        end

        it "net io" do
          used_metric = used_average_for(:net_usage_rate_average, hours_in_day, @vm1)
          expect(subject.net_io_used_metric).to eq(used_metric)
          expect(subject.net_io_used_cost).to eq(used_metric * hourly_rate * hours_in_day)
        end

        it "storage" do
          used_metric = used_average_for(:derived_vm_used_disk_storage, hours_in_day, @vm1)
          expect(subject.storage_used_metric).to eq(used_metric)
          expect(subject.storage_used_cost).to eq(used_metric / 1.gigabyte * count_hourly_rate * hours_in_day)

          expect(subject.storage_allocated_metric).to eq(vm_allocated_disk_storage.gigabytes)
          storage_allocated_cost = vm_allocated_disk_storage * count_hourly_rate * hours_in_day
          expect(subject.storage_allocated_cost).to eq(storage_allocated_cost)

          expect(subject.storage_cost).to eq(subject.storage_allocated_cost + subject.storage_used_cost)
        end

        it 'calculates metering used hours and cost' do
          expect(subject.metering_used_metric).to eq(hours_in_day)
          expect(subject.metering_used_cost).to eq(hours_in_day * count_hourly_rate)
        end

        context "fixed rates" do
          let(:hourly_fixed_rate) { 10.0 }

          before do
            set_tier_param_for(:derived_vm_used_disk_storage, :fixed_rate, hourly_fixed_rate)
            set_tier_param_for(:derived_vm_allocated_disk_storage, :fixed_rate, hourly_fixed_rate)
            set_tier_param_for(:derived_vm_used_disk_storage, :variable_rate, 0.0)
            set_tier_param_for(:derived_vm_allocated_disk_storage, :variable_rate, 0.0)
          end

          it "storage metrics" do
            expect(subject.storage_allocated_metric).to eq(vm_allocated_disk_storage.gigabytes)
            used_metric = used_average_for(:derived_vm_used_disk_storage, hours_in_day, @vm1)
            expect(subject.storage_used_metric).to eq(used_metric)

            expected_value = hourly_fixed_rate * hours_in_day
            expect(subject.storage_allocated_cost).to be_within(0.01).of(expected_value)

            expected_value = hourly_fixed_rate * hours_in_day
            expect(subject.storage_used_cost).to be_within(0.01).of(expected_value)
            expect(subject.storage_cost).to eq(subject.storage_allocated_cost + subject.storage_used_cost)
          end
        end
      end

      context "Report a chargeback of a tenant" do
        let(:options_tenant) { base_options.merge(:tenant_id => @tenant.id).tap { |t| t.delete(:tag) } }

        let(:start_time)  { report_run_time - 17.hours }
        let(:finish_time) { report_run_time - 14.hours }

        before do
          @tenant = FactoryGirl.create(:tenant)
          @tenant_child = FactoryGirl.create(:tenant, :parent => @tenant)
          @vm_tenant = FactoryGirl.create(:vm_vmware, :tenant_id => @tenant_child.id,
                                          :name => "test_vm_tenant", :created_on => month_beginning)

          add_metric_rollups_for(@vm_tenant, start_time...finish_time, 1.hour, metric_rollup_params)
        end

        subject { ChargebackVm.build_results_for_report_ChargebackVm(options_tenant).first.first }

        it "report a chargeback of a subtenant" do
          expect(subject.vm_name).to eq(@vm_tenant.name)
        end
      end

      context "Monthly" do
        context "calculation of allocated metrics by average" do
          let(:start_time)  { report_run_time - 17.hours }
          let(:finish_time) { report_run_time - 14.hours }
          let(:options) { base_options.merge(:interval => 'monthly', :method_for_allocated_metrics => :avg) }

          before do
            mid_point = month_beginning + 10.days
            add_metric_rollups_for(@vm1, month_beginning...mid_point, 1.hour, metric_rollup_params)
            add_metric_rollups_for(@vm1, mid_point...month_end, 1.hour, metric_rollup_params.merge!(:derived_vm_numvcpus => 2))
          end

          subject { ChargebackVm.build_results_for_report_ChargebackVm(options).first.first }

          it "calculates cpu allocated metric" do
            expect(subject.cpu_allocated_metric).to eq(1.6666666666666667)
            expect(subject.cpu_allocated_cost).to eq(1200) # ?
          end
        end
      end

      context 'monthly report, group by tenants' do
        let(:options) do
          {
            :interval                     => "monthly",
            :interval_size                => 12,
            :end_interval_offset          => 1,
            :tenant_id                    => tenant_1.id,
            :method_for_allocated_metrics => :max,
            :include_metrics              => true,
            :groupby                      => "tenant",
          }
        end

        let(:monthly_used_rate)      { hourly_rate * hours_in_month }
        let(:monthly_allocated_rate) { count_hourly_rate * hours_in_month }

        # My Company
        #   \___Tenant 2
        #   \___Tenant 3
        #     \__Tenant 4
        #     \__Tenant 5
        #
        let(:tenant_1) { Tenant.root_tenant }
        let(:vm_1_1)   { FactoryGirl.create(:vm_vmware, :tenant => tenant_1, :miq_group => nil) }
        let(:vm_2_1)   { FactoryGirl.create(:vm_vmware, :tenant => tenant_1, :miq_group => nil) }

        let(:tenant_2) { FactoryGirl.create(:tenant, :name => 'Tenant 2', :parent => tenant_1) }
        let(:vm_1_2)   { FactoryGirl.create(:vm_vmware, :tenant => tenant_2, :miq_group => nil) }
        let(:vm_2_2)   { FactoryGirl.create(:vm_vmware, :tenant => tenant_2, :miq_group => nil) }

        let(:tenant_3) { FactoryGirl.create(:tenant, :name => 'Tenant 3', :parent => tenant_1) }
        let(:vm_1_3)   { FactoryGirl.create(:vm_vmware, :tenant => tenant_3, :miq_group => nil) }
        let(:vm_2_3)   { FactoryGirl.create(:vm_vmware, :tenant => tenant_3, :miq_group => nil) }

        let(:tenant_4) { FactoryGirl.create(:tenant, :name => 'Tenant 4', :divisible => false, :parent => tenant_3) }
        let(:vm_1_4)   { FactoryGirl.create(:vm_vmware, :tenant => tenant_4, :miq_group => nil) }
        let(:vm_2_4)   { FactoryGirl.create(:vm_vmware, :tenant => tenant_4, :miq_group => nil) }

        let(:tenant_5) { FactoryGirl.create(:tenant, :name => 'Tenant 5', :divisible => false, :parent => tenant_3) }
        let(:vm_1_5)   { FactoryGirl.create(:vm_vmware, :tenant => tenant_5, :miq_group => nil) }
        let(:vm_2_5)   { FactoryGirl.create(:vm_vmware, :tenant => tenant_5, :miq_group => nil) }

        subject { ChargebackVm.build_results_for_report_ChargebackVm(options).first }

        let(:derived_vm_numvcpus_tenant_5) { 1 }
        let(:cpu_usagemhz_rate_average_tenant_5) { 50 }

        before do
          add_metric_rollups_for([vm_1_1, vm_2_1], month_beginning...month_end, 8.hours, metric_rollup_params.merge!(:derived_vm_numvcpus => 1, :cpu_usagemhz_rate_average => 50))
          add_metric_rollups_for([vm_1_2, vm_2_2], month_beginning...month_end, 8.hours, metric_rollup_params.merge!(:derived_vm_numvcpus => 1, :cpu_usagemhz_rate_average => 50))
          add_metric_rollups_for([vm_1_3, vm_2_3], month_beginning...month_end, 8.hours, metric_rollup_params.merge!(:derived_vm_numvcpus => 1, :cpu_usagemhz_rate_average => 50))
          add_metric_rollups_for([vm_1_4, vm_2_4], month_beginning...month_end, 8.hours, metric_rollup_params.merge!(:derived_vm_numvcpus => 1, :cpu_usagemhz_rate_average => 50))
          add_metric_rollups_for([vm_1_5, vm_2_5], month_beginning...month_end, 8.hours, metric_rollup_params.merge!(:derived_vm_numvcpus => derived_vm_numvcpus_tenant_5, :cpu_usagemhz_rate_average => cpu_usagemhz_rate_average_tenant_5))
        end

        it 'reports each tenants' do
          expect(subject.map(&:tenant_name)).to match_array([tenant_1, tenant_2, tenant_3, tenant_4, tenant_5].map(&:name))
        end

        def subject_row_for_tenant(tenant)
          subject.detect { |x| x.tenant_name == tenant.name }
        end

        let(:hourly_usage) { 30 * 3.0 / 720 } # count of metric rollups / hours in month

        it 'calculates allocated,used metric with using max,avg method with vcpus=1.0 and 50% usage' do
          # sum of maxes from each VM:
          # (max from first tenant_1's VM +  max from second tenant_1's VM) * monthly_allocated_rate
          expect(subject_row_for_tenant(tenant_1).cpu_allocated_metric).to eq(1 + 1)
          expect(subject_row_for_tenant(tenant_1).cpu_allocated_cost).to eq((1 + 1) * monthly_allocated_rate)

          expect(subject_row_for_tenant(tenant_2).cpu_allocated_metric).to eq(1 + 1)
          expect(subject_row_for_tenant(tenant_2).cpu_allocated_cost).to eq((1 + 1) * monthly_allocated_rate)

          expect(subject_row_for_tenant(tenant_3).cpu_allocated_metric).to eq(1 + 1)
          expect(subject_row_for_tenant(tenant_3).cpu_allocated_cost).to eq((1 + 1) * monthly_allocated_rate)

          expect(subject_row_for_tenant(tenant_4).cpu_allocated_metric).to eq(1 + 1)
          expect(subject_row_for_tenant(tenant_4).cpu_allocated_cost).to eq((1 + 1) * monthly_allocated_rate)

          expect(subject_row_for_tenant(tenant_5).cpu_allocated_metric).to eq(1 + 1)
          expect(subject_row_for_tenant(tenant_5).cpu_allocated_cost).to eq((1 + 1) * monthly_allocated_rate)

          # each tenant has 2 VMs and each VM  has 50 of cpu usage:
          # 5 tenants(tenant_1 has 4 tenants and plus tenant_1 ) * 2 VMs * 50% of usage
          expect(subject_row_for_tenant(tenant_1).cpu_used_metric).to eq(2 * 50 * hourly_usage)
          # and cost - there is multiplication by monthly_used_rate
          expect(subject_row_for_tenant(tenant_1).cpu_used_cost).to eq(2 * 50 * hourly_usage * monthly_used_rate)

          expect(subject_row_for_tenant(tenant_2).cpu_used_metric).to eq(2 * 50 * hourly_usage)
          expect(subject_row_for_tenant(tenant_2).cpu_used_cost).to eq(2 * 50 * hourly_usage * monthly_used_rate)

          expect(subject_row_for_tenant(tenant_3).cpu_used_metric).to eq(2 * 50 * hourly_usage)
          expect(subject_row_for_tenant(tenant_3).cpu_used_cost).to eq(2 * 50 * hourly_usage * monthly_used_rate)

          expect(subject_row_for_tenant(tenant_4).cpu_used_metric).to eq(2 * 50 * hourly_usage)
          expect(subject_row_for_tenant(tenant_4).cpu_used_cost).to eq(2 * 50 * hourly_usage * monthly_used_rate)

          expect(subject_row_for_tenant(tenant_5).cpu_used_metric).to eq(2 * 50 * hourly_usage)
          expect(subject_row_for_tenant(tenant_5).cpu_used_cost).to eq(2 * 50 * hourly_usage * monthly_used_rate)
        end

        context 'vcpu=5 for VMs of tenant_5' do
          let(:derived_vm_numvcpus_tenant_5)       { 5 }
          let(:cpu_usagemhz_rate_average_tenant_5) { 75 }

          it 'calculates allocated,used metric with using max,avg method with vcpus=1.0 and 50% usage' do
            expect(subject_row_for_tenant(tenant_1).cpu_allocated_metric).to eq(1 + 1)
            expect(subject_row_for_tenant(tenant_1).cpu_allocated_cost).to eq((1 + 1) * monthly_allocated_rate)

            expect(subject_row_for_tenant(tenant_2).cpu_allocated_metric).to eq(1 + 1)
            expect(subject_row_for_tenant(tenant_2).cpu_allocated_cost).to eq((1 + 1) * monthly_allocated_rate)

            expect(subject_row_for_tenant(tenant_3).cpu_allocated_metric).to eq(1 + 1)
            expect(subject_row_for_tenant(tenant_3).cpu_allocated_cost).to eq((1 + 1) * monthly_allocated_rate)

            expect(subject_row_for_tenant(tenant_4).cpu_allocated_metric).to eq(1 + 1)
            expect(subject_row_for_tenant(tenant_4).cpu_allocated_cost).to eq((1 + 1) * monthly_allocated_rate)

            expect(subject_row_for_tenant(tenant_5).cpu_allocated_metric).to eq(5 + 5)
            expect(subject_row_for_tenant(tenant_5).cpu_allocated_cost).to eq((5 + 5) * monthly_allocated_rate)

            # each tenant has 2 VMs and each VM  has 50 of cpu usage:
            # 5 tenants(tenant_1 has 4 tenants and plus tenant_1 ) * 2 VMs * 50% of usage
            # but tenant_5 has  2 VMs and each VM  has 75 of cpu usage
            expect(subject_row_for_tenant(tenant_1).cpu_used_metric).to eq(hourly_usage * 2 * 50)
            # and cost - there is multiplication by  monthly_used_rate
            expect(subject_row_for_tenant(tenant_1).cpu_used_cost).to eq(hourly_usage * 2 * 50 * monthly_used_rate)

            expect(subject_row_for_tenant(tenant_2).cpu_used_metric).to eq(hourly_usage * 2 * 50)
            expect(subject_row_for_tenant(tenant_2).cpu_used_cost).to eq(hourly_usage * 2 * 50 * monthly_used_rate)

            expect(subject_row_for_tenant(tenant_3).cpu_used_metric).to eq(hourly_usage * 2 * 50)
            expect(subject_row_for_tenant(tenant_3).cpu_used_cost).to eq(hourly_usage * 2 * 50 * monthly_used_rate)

            expect(subject_row_for_tenant(tenant_4).cpu_used_metric).to eq(hourly_usage * 2 * 50)
            expect(subject_row_for_tenant(tenant_4).cpu_used_cost).to eq(hourly_usage * 2 * 50 * monthly_used_rate)

            expect(subject_row_for_tenant(tenant_5).cpu_used_metric).to eq(hourly_usage * 2 * 75)
            expect(subject_row_for_tenant(tenant_5).cpu_used_cost).to eq(hourly_usage * 2 * 75 * monthly_used_rate)
          end

          context 'test against group by vm report' do
            let(:options_group_vm) do
              {
                :interval                     => "monthly",
                :interval_size                => 12,
                :end_interval_offset          => 1,
                :tenant_id                    => tenant_1.id,
                :method_for_allocated_metrics => :max,
                :include_metrics              => true,
                :groupby                      => "vm"
              }
            end

            def result_row_for_vm(vm)
              result_group_by_vm.detect { |x| x.vm_name == vm.name }
            end

            let(:result_group_by_vm) { ChargebackVm.build_results_for_report_ChargebackVm(options_group_vm).first }

            it 'calculates used metric and cost same as report for each vm' do
              # Tenant 1 VMs
              all_vms_cpu_metric = [vm_1_1, vm_2_1].map { |vm| result_row_for_vm(vm).cpu_used_metric }.sum
              all_vms_cpu_cost   = [vm_1_1, vm_2_1].map { |vm| result_row_for_vm(vm).cpu_used_cost }.sum

              # Tenant 1
              expect(subject_row_for_tenant(tenant_1).cpu_used_metric).to eq(all_vms_cpu_metric)
              expect(subject_row_for_tenant(tenant_1).cpu_used_cost).to eq(all_vms_cpu_cost)

              # Tenant 5 Vms
              result_vm15 = result_row_for_vm(vm_1_5)
              result_vm25 = result_row_for_vm(vm_2_5)

              expect(subject_row_for_tenant(tenant_5).cpu_used_metric).to eq(result_vm15.cpu_used_metric + result_vm25.cpu_used_metric)
              expect(subject_row_for_tenant(tenant_5).cpu_used_cost).to eq(result_vm15.cpu_used_cost + result_vm25.cpu_used_cost)
            end

            it 'calculated allocted metric and cost with using max(max is not summed up - it is taken maximum)' do
              # Tenant 1 VMs
              all_vms_cpu_metric = [vm_1_1, vm_2_1].map { |vm| result_row_for_vm(vm).cpu_allocated_metric }.sum
              all_vms_cpu_cost   = [vm_1_1, vm_2_1].map { |vm| result_row_for_vm(vm).cpu_allocated_cost }.sum

              expect(subject_row_for_tenant(tenant_1).cpu_allocated_metric).to eq(all_vms_cpu_metric)
              expect(subject_row_for_tenant(tenant_1).cpu_allocated_cost).to eq(all_vms_cpu_cost)
            end
          end
        end
      end

      context "Monthly" do
        let(:options) { base_options.merge(:interval => 'monthly') }
        before do
          add_metric_rollups_for(@vm1, month_beginning...month_end, 12.hours, metric_rollup_params)
        end

        subject { ChargebackVm.build_results_for_report_ChargebackVm(options).first.first }

        it "cpu" do
          expect(subject.cpu_allocated_metric).to eq(cpu_count)
          used_metric = used_average_for(:cpu_usagemhz_rate_average, hours_in_month, @vm1)
          expect(subject.cpu_used_metric).to be_within(0.01).of(used_metric)
          expect(subject.cpu_used_cost).to be_within(0.01).of(used_metric * hourly_rate * hours_in_month)
          expect(subject.cpu_allocated_cost).to be_within(0.01).of(cpu_count * count_hourly_rate * hours_in_month)
        end

        context 'with nonzero fixed rate' do
          let(:hourly_variable_tier_rate) { {:fixed_rate => 100, :variable_rate => hourly_rate.to_s} }

          it 'shows rates' do
            skip('this case needs to be added in new chargeback') if Settings.new_chargeback

            expect(subject.cpu_allocated_rate).to eq("0.0/1.0")
            expect(subject.cpu_used_rate).to eq("100.0/0.01")
            expect(subject.disk_io_used_rate).to eq("100.0/0.01")
            expect(subject.fixed_compute_1_rate).to eq("100.0/0.01")
            expect(subject.memory_allocated_rate).to eq("100.0/0.01")
            expect(subject.memory_used_rate).to eq("100.0/0.01")
            expect(subject.metering_used_rate).to eq("0.0/1.0")
            expect(subject.net_io_used_rate).to eq("100.0/0.01")
            expect(subject.storage_allocated_rate).to eq("0.0/1.0")
            expect(subject.storage_used_rate).to eq("0.0/1.0")
          end
        end

        let(:fixed_rate) { 10.0 }

        context "fixed and variable rate" do
          before do
            set_tier_param_for(:derived_vm_numvcpus, :fixed_rate, fixed_rate)
            set_tier_param_for(:cpu_usagemhz_rate_average, :fixed_rate, fixed_rate)
          end

          it "cpu" do
            expect(subject.cpu_allocated_metric).to eq(cpu_count)
            used_metric = used_average_for(:cpu_usagemhz_rate_average, hours_in_month, @vm1)
            expect(subject.cpu_used_metric).to be_within(0.01).of(used_metric)

            fixed = fixed_rate * hours_in_month
            variable = cpu_count * count_hourly_rate * hours_in_month
            expect(subject.cpu_allocated_cost).to be_within(0.01).of(fixed + variable)

            fixed = fixed_rate * hours_in_month
            variable = used_metric * hourly_rate * hours_in_month
            expect(subject.cpu_used_cost).to be_within(0.01).of(fixed + variable)
          end
        end

        it "memory" do
          expect(subject.memory_allocated_metric).to eq(memory_available)
          used_metric = used_average_for(:derived_memory_used, hours_in_month, @vm1)
          expect(subject.memory_used_metric).to be_within(0.01).of(used_metric)

          memory_allocated_cost = memory_available * hourly_rate * hours_in_month
          expect(subject.memory_allocated_cost).to be_within(0.01).of(memory_allocated_cost)
          expect(subject.memory_used_cost).to be_within(0.01).of(used_metric * hourly_rate * hours_in_month)
          expect(subject.memory_cost).to eq(subject.memory_allocated_cost + subject.memory_used_cost)
        end

        it "disk io" do
          used_metric = used_average_for(:disk_usage_rate_average, hours_in_month, @vm1)
          expect(subject.disk_io_used_metric).to be_within(0.01).of(used_metric)
          expect(subject.disk_io_used_cost).to be_within(0.01).of(used_metric * hourly_rate * hours_in_month)
        end

        it "net io" do
          used_metric = used_average_for(:net_usage_rate_average, hours_in_month, @vm1)
          expect(subject.net_io_used_metric).to be_within(0.01).of(used_metric)
          expect(subject.net_io_used_cost).to be_within(0.01).of(used_metric * hourly_rate * hours_in_month)
        end

        it 'calculates metering used hours and cost' do
          expect(subject.metering_used_metric).to eq(hours_in_month)
          expect(subject.metering_used_cost).to eq(count_hourly_rate * hours_in_month)
        end

        context "fixed rates" do
          let(:hourly_fixed_rate) { 10.0 }

          before do
            set_tier_param_for(:derived_vm_used_disk_storage, :fixed_rate, hourly_fixed_rate)
            set_tier_param_for(:derived_vm_allocated_disk_storage, :fixed_rate, hourly_fixed_rate)

            set_tier_param_for(:derived_vm_used_disk_storage, :variable_rate, 0.0)
            set_tier_param_for(:derived_vm_allocated_disk_storage, :variable_rate, 0.0)
          end

          it "storage with only fixed rates" do
            expect(subject.storage_allocated_metric).to eq(vm_allocated_disk_storage.gigabytes)
            used_metric = used_average_for(:derived_vm_used_disk_storage, hours_in_month, @vm1)
            expect(subject.storage_used_metric).to be_within(0.01).of(used_metric)

            expected_value = hourly_fixed_rate * hours_in_month
            expect(subject.storage_allocated_cost).to be_within(0.01).of(expected_value)

            expected_value = hourly_fixed_rate * hours_in_month
            expect(subject.storage_used_cost).to be_within(0.01).of(expected_value)
            expect(subject.storage_cost).to eq(subject.storage_allocated_cost + subject.storage_used_cost)
          end
        end

        it "storage" do
          expect(subject.storage_allocated_metric).to eq(vm_allocated_disk_storage.gigabytes)
          used_metric = used_average_for(:derived_vm_used_disk_storage, hours_in_month, @vm1)
          expect(subject.storage_used_metric).to be_within(0.01).of(used_metric)

          expected_value = vm_allocated_disk_storage * count_hourly_rate * hours_in_month
          expect(subject.storage_allocated_cost).to be_within(0.01).of(expected_value)
          expected_value = used_metric / 1.gigabytes * count_hourly_rate * hours_in_month
          expect(subject.storage_used_cost).to be_within(0.01).of(expected_value)
          expect(subject.storage_cost).to eq(subject.storage_allocated_cost + subject.storage_used_cost)
        end

        context "by owner" do
          let(:user) { FactoryGirl.create(:user, :name => 'Test VM Owner', :userid => 'test_user') }
          let(:options) { {:interval_size => 4, :owner => user.userid, :ext_options => {:tz => 'Eastern Time (US & Canada)'} } }
          before do
            @vm1.update_attribute(:evm_owner, user)
          end

          it "valid" do
            expect(subject.owner_name).to eq(user.name)
          end

          it "not exist" do
            user.delete
            expect { subject }.to raise_error(MiqException::Error, "Unable to find user '#{user.userid}'")
          end
        end
      end

      describe "#get_rates" do
        let(:chargeback_rate)         { FactoryGirl.create(:chargeback_rate, :rate_type => "Compute") }
        let(:chargeback_vm)           { ChargebackVm.new }
        let(:rate_assignment_options) { {:cb_rate => chargeback_rate, :object => Tenant.root_tenant} }
        let(:metric_rollup) do
          FactoryGirl.create(:metric_rollup_vm_hr, :timestamp => report_run_time - 1.day - 17.hours,
                             :tag_names => "environment/prod",
                             :parent_host_id => @host1.id, :parent_ems_cluster_id => @ems_cluster.id,
                             :parent_ems_id => ems.id, :parent_storage_id => @storage.id,
                             :resource => @vm1)
        end
        let(:consumption) { Chargeback::ConsumptionWithRollups.new([metric_rollup], nil, nil) }

        before do
          ChargebackRate.set_assignments(:compute, [rate_assignment_options])
          @rate = Chargeback::RatesCache.new.get(consumption).first
          @assigned_rate = ChargebackRate.get_assignments("Compute").first
        end

        it "return tenant chargeback detail rate" do
          expect(@rate).not_to be_nil
          expect(@rate.id).to eq(@assigned_rate[:cb_rate].id)
        end

        context "selecting based on tagged cloud volumes" do
          let!(:cloud_volume_sdd) { FactoryGirl.create(:cloud_volume_openstack, :volume_type => 'sdd') }

          let(:ssd_size) { 1_234 }
          let(:ssd_disk) { FactoryGirl.create(:disk, :size => ssd_size, :backing => cloud_volume_sdd) }
          let(:hardware) { FactoryGirl.create(:hardware, :disks => [ssd_disk]) }

          let(:resource) { FactoryGirl.create(:vm_vmware_cloud, :hardware => hardware, :created_on => month_beginning) }

          let(:consumption) { Chargeback::ConsumptionWithoutRollups.new(resource, nil, nil) }

          let(:storage_chargeback_rate) { FactoryGirl.create(:chargeback_rate, :rate_type => "Storage") }

          let(:parent_classification) { FactoryGirl.create(:classification) }
          let(:classification)        { FactoryGirl.create(:classification, :parent_id => parent_classification.id) }

          let(:rate_assignment_options) { {:cb_rate => storage_chargeback_rate, :tag => [classification, "storage"]} }

          subject { Chargeback::RatesCache.new.get(consumption).first }

          it "chooses rate according to cloud_volume\'s tag" do
            skip('this feature needs to be added to new chargeback assignments') if Settings.new_chargeback

            cloud_volume_sdd.tag_with([classification.tag.name], :ns => '*')

            ChargebackRate.set_assignments(:storage, [rate_assignment_options])
            expect(subject).to eq(storage_chargeback_rate)
          end

          it "doesn't choose rate thanks to missing tag on cloud_volume" do
            skip('this feature needs to be added to new chargeback assignments') if Settings.new_chargeback

            ChargebackRate.set_assignments(:storage, [rate_assignment_options])

            @rate = Chargeback::RatesCache.new.get(consumption).first
            expect(subject).to be_nil
          end
        end
      end

      describe '.report_row_key' do
        let(:report_options) { Chargeback::ReportOptions.new }
        let(:timestamp_key) { 'Fri, 13 May 2016 10:40:00 UTC +00:00' }
        let(:beginning_of_day) { timestamp_key.in_time_zone.beginning_of_day }
        let(:metric_rollup) { FactoryGirl.build(:metric_rollup_vm_hr, :timestamp => timestamp_key, :resource => @vm1) }
        let(:consumption) { Chargeback::ConsumptionWithRollups.new([metric_rollup], nil, nil) }
        subject { described_class.report_row_key(consumption) }
        before do
          described_class.instance_variable_set(:@options, report_options)
        end

        it { is_expected.to eq("#{metric_rollup.resource_id}_#{beginning_of_day}") }
      end

      describe '#initialize' do
        let(:report_options) { Chargeback::ReportOptions.new }
        let(:vm_owners)     { {@vm1.id => @vm1.evm_owner_name} }
        let(:consumption) { Chargeback::ConsumptionWithRollups.new([metric_rollup], nil, nil) }
        let(:shared_extra_fields) do
          {'vm_name' => @vm1.name, 'owner_name' => admin.name, 'vm_uid' => 'ems_ref', 'vm_guid' => @vm1.guid,
           'vm_id' => @vm1.id}
        end
        subject { ChargebackVm.new(report_options, consumption).attributes }

        before do
          ChargebackVm.instance_variable_set(:@vm_owners, vm_owners)
        end

        context 'with parent ems' do
          let(:metric_rollup) do
            FactoryGirl.build(:metric_rollup_vm_hr, :tag_names => 'environment/prod',
                              :parent_host_id => @host1.id, :parent_ems_cluster_id => @ems_cluster.id,
                              :parent_ems_id => ems.id, :parent_storage_id => @storage.id,
                              :resource => @vm1, :resource_name => @vm1.name)
          end

          it 'sets extra fields' do
            is_expected.to include(shared_extra_fields.merge('provider_name' => ems.name, 'provider_uid' => ems.guid))
          end
        end

        context 'when parent ems is missing' do
          let(:metric_rollup) do
            FactoryGirl.build(:metric_rollup_vm_hr, :tag_names => 'environment/prod',
                              :parent_host_id => @host1.id, :parent_ems_cluster_id => @ems_cluster.id,
                              :parent_storage_id => @storage.id,
                              :resource => @vm1, :resource_name => @vm1.name)
          end

          it 'sets extra fields when parent ems is missing' do
            is_expected.to include(shared_extra_fields.merge('provider_name' => nil, 'provider_uid' => nil))
          end
        end
      end

      context 'more rates have been selected' do
        let(:storage_chargeback_rate_1) { FactoryGirl.create(:chargeback_rate, :rate_type => "Storage") }
        let(:storage_chargeback_rate_2) { FactoryGirl.create(:chargeback_rate, :rate_type => "Storage") }
        let(:chargeback_vm)             { Chargeback::RatesCache.new }

        let(:parent_classification) { FactoryGirl.create(:classification) }
        let(:classification_1)      { FactoryGirl.create(:classification, :parent_id => parent_classification.id) }
        let(:classification_2)      { FactoryGirl.create(:classification, :parent_id => parent_classification.id) }

        let(:rate_assignment_options_1) { {:cb_rate => storage_chargeback_rate_1, :tag => [classification_1, "Storage"]} }
        let(:rate_assignment_options_2) { {:cb_rate => storage_chargeback_rate_2, :tag => [classification_2, "Storage"]} }

        let(:metric_rollup) do
          FactoryGirl.create(:metric_rollup_vm_hr, :timestamp => report_run_time - 1.day - 17.hours,
                             :parent_host_id => @host1.id, :parent_ems_cluster_id => @ems_cluster.id,
                             :parent_ems_id => ems.id, :parent_storage_id => @storage.id,
                             :resource => @vm1)
        end
        let(:consumption) { Chargeback::ConsumptionWithRollups.new([metric_rollup], nil, nil) }

        before do
          @storage.tag_with([classification_1.tag.name, classification_2.tag.name], :ns => '*')
          ChargebackRate.set_assignments(:storage, [rate_assignment_options_1, rate_assignment_options_2])
        end

        it "return only one chargeback rate according to tag name of Vm" do
          [rate_assignment_options_1, rate_assignment_options_2].each do |rate_assignment|
            metric_rollup.tag_names = rate_assignment[:tag].first.tag.send(:name_path)
            uniq_rates = chargeback_vm.get(consumption)
            consumption.instance_variable_set(:@tag_names, nil)
            consumption.instance_variable_set(:@hash_features_affecting_rate, nil)
            expect([rate_assignment[:cb_rate]]).to match_array(uniq_rates)
          end
        end
      end

      context "Group by tags" do
        let(:options) { base_options.merge(:interval => 'monthly', :groupby_tag => 'environment') }
        before do
          add_metric_rollups_for(@vm1, month_beginning...month_end, 12.hours, metric_rollup_params)
        end

        subject { ChargebackVm.build_results_for_report_ChargebackVm(options).first.first }

        it "cpu" do
          expect(subject.cpu_allocated_metric).to eq(cpu_count)
          used_metric = used_average_for(:cpu_usagemhz_rate_average, hours_in_month, @vm1)
          expect(subject.cpu_used_metric).to be_within(0.01).of(used_metric)
          expect(subject.tag_name).to eq('Production')
        end
      end
    end

    context 'without metric rollups' do
      let(:cores)               { 7 }
      let(:mem_mb)              { 1777 }
      let(:disk_gb)             { 7 }
      let(:disk_b)              { disk_gb * 1024**3 }
      let(:metering_used_hours) { 24 }

      let(:hardware) do
        FactoryGirl.build(:hardware,
                          :cpu_total_cores => cores,
                          :memory_mb       => mem_mb,
                          :disks           => [FactoryGirl.build(:disk, :size => disk_b)])
      end

      let(:fixed_cost) { hourly_rate * 24 }
      let(:mem_cost) { mem_mb * hourly_rate * 24 }
      let(:cpu_cost) { cores * count_hourly_rate * 24 }
      let(:disk_cost) { disk_gb * count_hourly_rate * 24 }
      let(:metering_used_cost) { metering_used_hours * count_hourly_rate }

      context 'for SCVMM (hyper-v)' do
        let!(:vm1) do
          vm = FactoryGirl.create(:vm_microsoft, :hardware => hardware, :created_on => report_run_time - 1.day)
          vm.tag_with(@tag.name, :ns => '*')
          vm
        end

        let(:options) { base_options.merge(:interval => 'daily') }

        subject { ChargebackVm.build_results_for_report_ChargebackVm(options).first.first }

        it 'fixed compute is calculated properly' do
          expect(subject.chargeback_rates).to eq(chargeback_rate.description)
          expect(subject.fixed_compute_metric).to eq(1) # One day of fixed compute metric
          expect(subject.fixed_compute_1_cost).to eq(fixed_cost)
        end

        it 'allocated metrics are calculated properly' do
          expect(subject.memory_allocated_metric).to  eq(mem_mb)
          expect(subject.memory_allocated_cost).to    eq(mem_cost)
          expect(subject.metering_used_metric).to  eq(metering_used_hours)
          expect(subject.metering_used_cost).to    eq(metering_used_cost)
          expect(subject.cpu_allocated_metric).to     eq(cores)
          expect(subject.cpu_allocated_cost).to       eq(cpu_cost)
          expect(subject.storage_allocated_metric).to eq(disk_b)
          expect(subject.storage_allocated_cost).to   eq(disk_cost)
          expect(subject.total_cost).to               eq(fixed_cost + cpu_cost + mem_cost + disk_cost + metering_used_cost)
        end
      end

      context 'for any virtual machine' do
        let!(:vm1) do
          vm = FactoryGirl.create(:vm_vmware, :hardware => hardware, :created_on => report_run_time - 1.day)
          vm.tag_with(@tag.name, :ns => '*')
          vm
        end

        subject { ChargebackVm.build_results_for_report_ChargebackVm(options).first.first }

        let(:options) { base_options.merge(:interval => 'daily', :include_metrics => false) }

        it 'fixed compute is calculated properly' do
          expect(subject.chargeback_rates).to eq(chargeback_rate.description)
          expect(subject.fixed_compute_metric).to eq(1) # One day of fixed compute metric
          expect(subject.fixed_compute_1_cost).to eq(fixed_cost)
        end

        it 'metrics are calculated properly' do
          expect(subject.memory_allocated_metric).to  eq(mem_mb)
          expect(subject.memory_allocated_cost).to    eq(mem_cost)
          expect(subject.metering_used_metric).to  eq(metering_used_hours)
          expect(subject.metering_used_cost).to    eq(metering_used_cost)
          expect(subject.cpu_allocated_metric).to     eq(cores)
          expect(subject.cpu_allocated_cost).to       eq(cpu_cost)
          expect(subject.storage_allocated_metric).to eq(disk_b)
          expect(subject.storage_allocated_cost).to   eq(disk_cost)

          expect(subject.total_cost).to               eq(fixed_cost + cpu_cost + mem_cost + disk_cost + metering_used_cost)
        end

        context 'metrics are included (but dont have any)' do
          it 'is not generating report with options[:include_metrics]=true' do
            options[:include_metrics] = true
            expect(subject).to be_nil
          end

          it 'is not generating report with options[:include_metrics]=nil(default value)' do
            options[:include_metrics] = nil
            expect(subject).to be_nil
          end
        end
      end
    end
  end

  context "Old Chargeback" do
    include_examples "ChargebackVm"
  end

  context "New Chargeback" do
    before do
      ManageIQ::Showback::InputMeasure.seed

      stub_settings(:new_chargeback => '1')
    end

    include_examples "ChargebackVm"
  end
end
