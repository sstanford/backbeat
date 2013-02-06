module WorkflowServer
  module Models
    class Decision < Event

      after_create :schedule_next_decision

      attr_accessor :decisions_to_add

      def start
        super
        update_status!(:enqueued)
        WorkflowServer::Async::Job.schedule(event: self, method: :send_to_client, max_attempts: 25)
      end

      def change_status(new_status, args = {})
        return if status == new_status.try(:to_sym)
        case new_status.to_sym
        when :deciding
          raise WorkflowServer::InvalidEventStatus, "Decision #{self.name} can't transition from #{status} to #{new_status}" unless [:deciding, :enqueued, :timeout].include?(status)
          deciding
        when :deciding_complete
          raise WorkflowServer::InvalidEventStatus, "Decision #{self.name} can't transition from #{status} to #{new_status}" unless [:enqueued, :deciding, :timeout].include?(status)
          self.decisions_to_add = []
          (args[:decisions] || []).each do |decision|
            add_new_decision(HashWithIndifferentAccess.new(decision))
          end
          close
        when :errored
          raise WorkflowServer::InvalidEventStatus, "Decision #{self.name} can't transition from #{status} to #{new_status}" unless [:enqueued, :deciding, :timeout].include?(status)
          errored(args[:error])
        else
          raise WorkflowServer::InvalidEventStatus, "Invalid status #{new_status}"
        end
      end

      def completed
        self.children << Flag.create(name: "#{self.name}_completed".to_sym, workflow: workflow, parent: self, status: :complete)
        super
        schedule_next_decision
      end

      def child_completed(child)
        super
        if child.is_a?(Activity) || child.is_a?(Branch) || child.is_a?(Workflow)
          refresh
        end
      end

      def errored(error)
        super
      end

      def serializable_hash(options = {})
        hash = super
        hash.merge({ past_flags: past_flags.map(&:name), decider: workflow.decider, subject_klass: workflow.subject_klass, subject_id: workflow.subject_id })
      end

      private

      def deciding
        update_status!(:deciding)
        Watchdog.feed(self, :decision_deciding_time_out)
      end

      def close
        Watchdog.dismiss(self, :decision_deciding_time_out)
        decisions = decisions_to_add.map do |type, args|
          type.new(args.merge(workflow: workflow, parent: self))
        end

        if decisions.any?{|d| !d.valid?}
          invalid_decisions = decisions.select{|d| !d.valid? }
          raise WorkflowServer::InvalidParameters, invalid_decisions.map{|d| {d.event_type => d.errors}}
        else
          decisions.each{|d| d.save!}
        end
        reload

        unless decisions.empty?
          update_status!(:executing)
        end
        refresh
      end

      def refresh
        reload
        start_next_action
        completed if all_activities_branches_and_workflows_completed?
      end

      def add_flag(name)
        decisions_to_add << [Flag, {name: name, parent: self, workflow: workflow}]
      end

      def add_timer(name, fires_at = Time.now)
        decisions_to_add << [Timer, {fires_at: fires_at, name: name, parent: self, workflow: workflow}]
      end

      def add_activity(name, options = {})
        decisions_to_add << [Activity, {name: name, workflow: workflow, parent: self}.merge(options)]
      end

      def add_branch(name, options = {})
        decisions_to_add << [Branch, {name: name, workflow: workflow, parent: self}.merge(options)]
      end

      def add_workflow(name, workflow_type, subject_klass, subject_id, decider, options = {})
        decisions_to_add << [Workflow, {name: name, workflow_type: workflow_type, subject_klass: subject_klass, subject_id: subject_id, decider: decider.to_s, workflow: workflow, parent: self, user: workflow.user}.merge(options)]
      end

      def complete_workflow
        decisions_to_add << [WorkflowCompleteFlag, {name: workflow.name, parent: self, workflow: workflow}]
      end

      def add_new_decision(options = {})
        case options.delete(:type).to_s
        when 'flag'
          add_flag(options[:name])
        when 'timer'
          add_timer(options[:name], options[:fires_at])
        when 'activity'
          add_activity(options.delete(:name), options)
        when 'branch'
          add_branch(options.delete(:name), options)
        when 'workflow'
          add_workflow(options.delete(:name), options.delete(:workflow_type), options.delete(:subject_klass), options.delete(:subject_id), options.delete(:decider), options)
        when 'complete_workflow'
          complete_workflow
        end
      end

      def start_next_action
        with_lock do
          open_events do |event|
            break if any_incomplete_blocking_activities_branches_or_workflows?
            event.start
          end
        end
      end

      def open_events
        Event.where(parent: self, status: :open).each do |event|
          yield event
        end
      end

      def any_incomplete_blocking_activities_branches_or_workflows?
        children.type([Activity, Branch, Workflow]).where(mode: :blocking).not_in(:status => [:complete, :open]).any?
      end

      def all_activities_branches_and_workflows_completed?
        !children.type([Activity, Branch, Workflow]).where(:mode.ne => :fire_and_forget, :status.ne => :complete).any?
      end

      def schedule_next_decision
        WorkflowServer.schedule_next_decision(workflow)
      end

      def send_to_client
        WorkflowServer::Client.make_decision(self)
        Watchdog.start(self, :decision_deciding_time_out)
      end

    end
  end
end
