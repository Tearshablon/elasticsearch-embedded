require 'elasticsearch/extensions/test/cluster'
require 'net/http'

module Elasticsearch
  module Embedded

    # Class used to manage a local cluster of elasticsearch nodes
    class Cluster

      # Options for cluster
      attr_accessor :port, :cluster_name, :nodes, :timeout, :persistent

      # Options for downloader
      attr_accessor :downloader, :version, :working_dir

      # Assign default values to options
      def initialize
        @nodes = 1
        @port = 9250
        @version = Downloader::DEFAULT_VERSION
        @working_dir = Downloader::TEMPORARY_PATH
      end

      # Start an elasticsearch cluster and return
      def start
        @downloader = Downloader.download(version: version, path: working_dir)
        Elasticsearch::Extensions::Test::Cluster.start(cluster_options)
        apply_development_template! if persistent
      end

      # Start an elasticsearch cluster and wait until running, also register
      # a signal handler to close the cluster on INT, TERM and QUIT signals
      def start_and_wait!
        start # start the cluster
        register_shutdown_handler
        # Wait for all child processes to end then return
        Process.waitall
      end

      # Stop the cluster and return
      def stop
        Elasticsearch::Extensions::Test::Cluster.stop(port: port)
      end

      def stop_and_wait!
        stop
        # Wait for all child processes to end then return
        Process.waitall
      end

      # Start server unless it's running
      def ensure_started!
        start unless running?
      end

      # Returns true when started cluster is running
      #
      # @return Boolean
      def running?
        Elasticsearch::Extensions::Test::Cluster.running? on: port, as: cluster_name
      end

      # Return running instances pids, borrowed from code in Elasticsearch::Extensions::Test::Cluster
      def pids
        # Try to fetch node info from running cluster
        nodes = JSON.parse(Net::HTTP.get(URI("http://localhost:#{port}/_nodes/?process"))) rescue []
        # Fetch pids from returned data
        nodes.empty? ? nodes : nodes['nodes'].map { |_, info| info['process']['id'] }
      end

      # Remove all indices in the cluster
      #
      # @return [Array<Net::HTTPResponse>] raw http responses
      def delete_all_indices!
        delete_index! :_all
      end

      # Remove the indices given as args
      #
      # @param [Array<String,Symbol>] args list of indices to delet
      # @return [Array<Net::HTTPResponse>] raw http responses
      def delete_index!(*args)
        args.map { |index| http_object.request(Net::HTTP::Delete.new("/#{index}")) }
      end

      # Used for persistent clusters, otherwise cluster won't get green state because of missing replicas
      def apply_development_template!
        development_settings = {
            template: '*',
            settings: {
                number_of_shards: 1,
                number_of_replicas: 0,
            }
        }
        # Create the template on cluster
        http_object.put('/_template/development_template', JSON.dump(development_settings))
      end

      private

      # Used as arguments for Elasticsearch::Extensions::Test::Cluster methods
      def cluster_options
        {
            port: port,
            nodes: nodes,
            cluster_name: cluster_name,
            timeout: timeout,
            # command to run is taken from downloader object
            command: downloader.executable,
        }.merge(persistency_options)
      end

      # Return options for data persistency
      def persistency_options
        persistent ?
            {
                gateway_type: 'local',
                index_store: 'mmapfs',
                path_data: File.join(downloader.working_dir, 'cluster_data'),
                path_work: File.join(downloader.working_dir, 'cluster_workdir'),
            } :
            {}
      end

      # Return an http object to make requests
      def http_object
        @http ||= Net::HTTP.new('localhost', port)
      end

      # Register a shutdown proc which handles INT, TERM and QUIT signals
      def register_shutdown_handler
        stopper = ->(sig) do
          puts "Received SIG#{Signal.signame(sig)}, quitting"
          stop
        end
        # Stop cluster on Ctrl+C, TERM (foreman) or QUIT (other)
        [:TERM, :INT, :QUIT].each { |sig| Signal.trap(sig, &stopper) }
      end

    end

  end
end
