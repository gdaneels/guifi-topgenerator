require "rexml/document"
require "ipaddr"
require "fileutils"
require "graph"

include REXML

class CNML
	attr_reader :nodes, :links

	def initialize(xmlfile, maxnodes)
		@xmlfile = xmlfile
		@doc = Document.new File.new(@xmlfile)
		@topology = Hash.new
		@maxnodes = maxnodes
		@not_chosen_nodes = Array.new
		@nodes = Array.new
		@links = Array.new {Array.new}
		@terminalCount = 0
		@corenet = IPAddr.new("172.0.0.0/8")
		@corenodes = Array.new
	end

	# Get all zones with minimum amount nodes nnodes.
	def getZonesMinNodes(minnodes)
		XPath.each( @doc, "//zone[@zone_nodes>=#{minnodes}]") { |element|
			puts element.attributes["title"]
		}
	end

	# Get all zones with max amount nodes nnodes.
	def getZonesMaxNodes(maxnodes)
		XPath.each( @doc, "//zone[@zone_nodes<=#{maxnodes}]") { |element|
			puts element.attributes["title"]
		}
	end

	def getZoneName(zoneID)
		XPath.each( @doc, "//zone[@id=#{zoneID}]") { |element|
			puts element.attributes["title"]
		}
	end
	
	# Get all nodes of a zone (by zone id)
	def getAllNodes(zoneID)
		XPath.each( @doc, "//zone[@id=#{zoneID}]") { |element|
			XPath.each( element, "//node") { |node|
				puts node.attributes["title"]
			}
		}
	end

	# Check whether it is a leaf node or not.
	def isNoLeafNode(nodeID)
		# check first in cached nodes
		if (@known_lnodes.include?(nodeID))
			return false
		elsif (@known_nodes.include?(nodeID))
			return true
		end

		# check in xml file
		node = XPath.first(@doc, "//node[@id=#{nodeID}]")
		if node != nil
			if (node.attributes["links"] == "1")
				puts nodeID.to_s + " -> LeafNode"
				@known_lnodes.push nodeID
				return false
			else
				puts nodeID.to_s + " -> Not a LeafNode"
				@known_nodes.push nodeID
				return true
			end
		else
			puts nodeID.to_s + " -> nilll"
			@known_lnodes.push nodeID
			return false
		end
	end

	# Get all neighbors of the node. [the none leaf nodes]
	def getAllNeighbors(nodeID)
		node = XPath.first(@doc, "//node[@id=#{nodeID}]")
		# We only count working nodes, nodes with other status don't have any links
		if ((node.attributes["status"] == "Working") && (isNoLeafNode nodeID))
			puts "Number of neighors: " + node.attributes["links"]
			neighbors = Array.new
			XPath.each(node, ".//link") {	|link|
				if (!neighbors.include?(link.attributes["linked_node_id"]) && (isNoLeafNode link.attributes["linked_node_id"]))
					puts "no leaf node added to neighbors: " + link.attributes["linked_node_id"]
					neighbors.push link.attributes["linked_node_id"]
				end
			}
			neighbors
		else
			return nil
		end
	end

	# Check for a core iface in that node with that iface id
	# By (my) definition, if a node contains a core interface, it is core node!
	def isCoreIface(nodeID, ifaceID)
		if $VERBOSE
			print "? isCoreIface: #{nodeID} , #{ifaceID}"
		end

		# check in xml file for the node with the given id
		node = XPath.first(@doc, "//node[@id=#{nodeID}]")
		# if we found the node
		if (node != nil)
			# check for the given interface
			iface =	XPath.first(node, ".//interface[@id=#{ifaceID}]")
			# check if the interface ip falls in the range
			if @corenet === iface.attributes["ipv4"].to_s
				if $VERBOSE
					puts " :: YES"
				end
				return true
			end
		end
		if $VERBOSE
			puts " :: NO"
		end
		return false
	end

	# Returns a hash with all the core interfaces of neighbors {ifaceID => nodeid of ifaceID, ...}
	def giveAllCoreNeighbors(nodeID)
		# coreneighbors = Hash.new
		coreneighbors = Array.new

		# check in xml file for the node with the given id
		node = XPath.first(@doc, "//node[@id=#{nodeID}]")
		# check in all the interfaces of that node
		XPath.each(node, ".//interface") { |iface|
			# check if the interface has a ipv4 address in the range of the corenet (has thus a router daemon)
			if @corenet === iface.attributes["ipv4"].to_s
				# check for all the links, if the link connects to other nodes with core interfaces
				# which makes those nodes also core nodes
				XPath.each(iface, ".//link") {	|link|
					if ((link.attributes["linked_node_id"].to_s != nodeID.to_s) && (isCoreIface(link.attributes["linked_node_id"], link.attributes["linked_interface_id"])))
						# In some cases the node links to itself...
						coreneighbors.push link.attributes["linked_node_id"]
					end
				}
			end
		}
		coreneighbors.uniq!
		return coreneighbors
	end

	# Recursively traverse nodes, searching for corenodes, starting from the node with id nodeID
	def traverseFromNode(nodeID)
		nodeID = nodeID.to_s
		if $VERBOSE
			puts " ######### Traversal from node #{nodeID} #########"
		end
		if (@terminalCount < 10)
			# if the topology already has this node
			if (@topology.include?(nodeID))
				# if the previous node was also a node that already was in the @topology
				if (@repeatNode == 1)
					# add 1 to the terminalCount, when the terminalCount reaches a treshold, the programs stops
					@terminalCount += 1
				end
				# if the node is already in @topology, ALWAYS put repeatNode = 1
				@repeatNode = 1
				if $VERBOSE
					puts "Detected node that is already in topology, number of repeated nodes in one sequece: #{@terminalCount}"
				end
			else (!@topology.include?(nodeID))
				# if the current node is not in the @topology, repeatNode is not valid, and the terminal count starts back from 0
				@repeatNode = 0
				@terminalCount = 0
			end

			# only if the it is not a repeatnode, we have to search for all the corenode neighbors again
			# if it is a repeatnode, this already happened and the neighbors are already added to the not_chosen_nodes list and topology
			if (@repeatNode == 0)
				# give all corenode neighbors of this node
				# corenode neighbors are nodes which have an interface with an IP in the corenet range
				nodes = giveAllCoreNeighbors nodeID

				# @not_chosen_nodes are all the corenodes, actually corenode neighbors, that are not yet "traversed" yet
				# add those nodes to the not chosen nodes
				@not_chosen_nodes.concat nodes

				# make sure no duplicates arise by concatenation
				@not_chosen_nodes.uniq!
				if $VERBOSE
					puts "Not chosen nodes yet:"
					puts @not_chosen_nodes
				end

				# put the node in the topology and add his coreneighbors as value
				# be aware that all nodes that in the topology are corenodes!
				@topology[nodeID] = nodes
				number = @topology.size
				if $VERBOSE
					puts "Added node #{nodeID} to the topology"
					puts "Current topology size = #{number}"
					puts "Topology:"
					puts @topology
				end			
			end

			# topology can not grow past the maximum allowed size
			if (@topology.size < @maxnodes)
				# as long as the not chosen nodes are not empty, keep on going
				if (!@not_chosen_nodes.empty?)
					# choose a random node 
					rand_node = @not_chosen_nodes.sample
					if $VERBOSE
						puts "Chosen one: #{rand_node}"
					end
					@not_chosen_nodes.delete(rand_node)
					# go recurively until the @maxnodes is exceeded or @not_chosen_nodes is empty
					traverseFromNode rand_node
					if $VERBOSE
						puts "Added #{rand_node}"
					end
				else	
					if $VERBOSE
						puts "No nodes left..."
					end
				end
			end
		else
			if $VERBOSE
				puts "<< !! REACHED MAXIMUM OF REPETITIONS !! >>"
			end
		end
	end

	# extract all the nodes from the topology
	def extractNodes
		@nodes.concat @topology.keys
	end

	# Extract the links between the nodes in the @topology
	# Make sure the nodes extracted from the @topology are also member of @nodes
	def extractLinks
		@topology.each { |node, neighbors|
			neighbors.each { |neighbor|
				# only if the neighbor is also a node in the topology, include the link
				# it could be that some neighbors are not in the topology because the topology may not exceed the @max_nodes
				if @nodes.include?(neighbor)
					a = Array.new
					a = [node.to_s, neighbor.to_s]
					b = Array.new
					b = [neighbor.to_s, node.to_s]
					# make sure if both ways are not yet in the @links (both are actually the same link)
					if (!@links.include?(a) && !@links.include?(b))
						@links.push a
					end
				end
			}
		}
		@links
	end
	
	def getTopologySize
		@topology.size
	end

	# Get all the nodes linked to the given node by a link.
	def getNodeLinkNodes(node)
		nodeLinks = Array.new
		@links.each do |link|
			if link.include?(node)
				# You know for sure the node is an element in an array of two.
				indexNode = link.index(node)

				# If the index of the node is 0, than the other node's index is 1, and otherwise.
				if (indexNode == 0)
					nodeLinks.push link[1]
				else
					nodeLinks.push link[0]
				end
			end
		end
		nodeLinks
	end

	def collectCoreNodes()
		corenodes = Array.new
		filename = "#{File.basename(@xmlfile, ".*")}-corenodes.txt"
		File.open(filename, 'w') do |file|  
			XPath.each(@doc, "//node") { |node|
				id = node.attributes['id']
				XPath.each(node, ".//interface") { |iface|
					# check if the interface has a ipv4 address in the range of the corenet (has thus a router daemon)
					if @corenet === iface.attributes["ipv4"].to_s
						if $VERBOSE						
							puts "Wrote #{id} to file..."
						end	
						corenodes.push id
						file.puts id
						break
					end
				}
			}
		end
		corenodes.uniq! # normally, cause of the break statement, this is redundant
		puts "Collected all corenodes in an array and in file #{filename}"
		return corenodes
	end

	# Create a visual graph of the topology
	def createGraph(dirname)
		links = Array.new {Array.new}
		links = @links
		digraph do
			node_attribs << lightblue << filled
			edge_attribs << arrowhead('none')
			links.each{ |link|
				edge "#{link[0]}", "#{link[1]}"
			}
			save "#{dirname}/languages", 'png'
		end
	end

	# Create the directory in which the topology will be saved
	def createTopologyDir()
		t = Time.now
		topologyName = "#{t.strftime("%Y-%m-%d-%H-%M-%S")}"
		FileUtils.mkdir topologyName
		return topologyName
	end

	# Write all the nodes of the created topology to a file
	def writeNodes(dirname)
		filename = "#{dirname}/nodes"
		File.open(filename, 'w') do |file|
			@nodes.each{ |node|
				file.puts "#{node}"
			}
		end
	end

	# Write all the links of the created topology to a file
	def writeLinks(dirname)
		filename = "#{dirname}/links"
		File.open(filename, 'w') do |file|
			@links.each{ |link|
				file.puts "#{link[0]} - #{link[1]}"
			}
		end
	end

	def createTopology(type)
		@corenodes = collectCoreNodes
		startNodeID = @corenodes.sample
		if $VERBOSE		
			puts "### Begin creating topology from node #{startNodeID} ###"
		end	
		traverseFromNode startNodeID
		if $VERBOSE
			puts "Size of topology: " + getTopologySize
		end

		# Check if the topology has the right size.
		if (getTopologySize < @maxnodes || getTopologySize > @maxnodes)
			puts "Topology - startNode #{startNodeID} - topology size (#{getTopologySize}) does NOT match wanted size (#{@maxnodes})! - No NS file created."
		elsif (getTopologySize == @maxnodes)
			dir = createTopologyDir
	
			# extract the nodes from the topology
			extractNodes
			# Write the nodes to a file
			writeNodes(dir)
			# extract the links from the topology
			extractLinks
			# Write the links to a file
			writeLinks(dir)
			# Create a visual graph
			createGraph(dir)

			if (type == "bmx")
				createVirtualBigLanBMX6("VirtualBMX6BigLan-#{startNodeID}-#{@maxnodes}")
			elsif (type == "olsr")
				createVirtualBigLanOLSRd("VirtualOLSRdBigLan-#{startNodeID}-#{@maxnodes}")
			end
			puts "Created topology from start node #{startNodeID} with a topology size of #{getTopologySize}"
		end
	
		if $VERBOSE		
			puts "### End creating topology from node #{startNodeID} ###"
		end

		return @topology
	end

	def createFilterFiles(dir)
		@links.each do |link|
			print "Link < "
    			link.each do |l|
    				print l + " "
			end
			print ">"
			puts ""
		end
		@nodes.each do |node|
			linkedNodes = getNodeLinkNodes(node)
			filename = "#{dir}/node#{node}.filter"
			File.open(filename, 'w') do |file| 
				linkedNodes.each do |lnode|
					file.puts "node#{lnode}\n"
				end
			end
		end
	end

		# Creates NS experiment file out of @nodes and @links extracted from the topology
	def createVirtualBigLanBMX6(suffix="VirtualBigLanBMX6")
		t = Time.now
		topologyName = "#{t.strftime("%Y-%m-%d-%H-%M-%S")}-#{suffix}"
		FileUtils.mkdir topologyName
		createFilterFiles topologyName
		# Create a new file and write to it
		
		filename = "#{topologyName}/#{topologyName}.ns"
		File.open(filename, 'w') do |file|  
  			# use "\n" for two lines of text  
  			file.puts "set ns [new Simulator]\n"			
        		file.puts "source tb_compat.tcl\n\n"

			file.puts "set nodeGroupInstall [$ns event-group]\n"
			file.puts "set nodeGroupWriteIPv6 [$ns event-group]\n"
			file.puts "set nodeGroupFilter [$ns event-group]\n"
			file.puts "set nodeGroupRouteCheck [$ns event-group]\n"
			file.puts "set nodeGroupInstallBMX6 [$ns event-group]\n"
			file.puts "set nodeGroupBMX6 [$ns event-group]\n"

			file.puts "set monitorSetupEnv [$ns event-group]\n"
			file.puts "set monitorSetRouter [$ns event-group]\n"
			file.puts "set monitorFailPass [$ns event-group]\n"
			file.puts "set monitorStartTcpdump [$ns event-group]\n"
			file.puts "set monitorStopTcpdump [$ns event-group]\n"
			file.puts "set monitorIntervalLog [$ns event-group]\n\n"
			
			# define the nodes
			@nodes.each do |node|
				file.puts "set node#{node} [$ns node]\n"
				# Automatically place BMX6 on the node (in dir /usr/local/src).
				file.puts "tb-set-node-tarfiles $node#{node} /usr/local/src/ /proj/CONFINE/tarfiles/bmx6.tar.gz"
				file.puts "append lanstr \"$node#{node} \"\n"

				file.puts "set progInstall#{node} [$node#{node} program-agent -command \"sudo /proj/CONFINE/runme-BMX6/virtual/install_ip6tables.sh\"]\n"
				file.puts "set progInstallBMX6#{node} [$node#{node} program-agent -command \"/proj/CONFINE/runme-BMX6/virtual/install_BMX6.sh\"]\n"
				file.puts "set progWriteIPv6#{node} [$node#{node} program-agent -command \"/proj/CONFINE/runme-BMX6/virtual/ipv6tofile.sh\"]\n"
				file.puts "set progFilter#{node} [$node#{node} program-agent -command \"/proj/CONFINE/runme-BMX6/virtual/filter_ip6tables.sh\"]\n"
				file.puts "set progRouteCheck#{node} [$node#{node} program-agent -command \"/proj/CONFINE/runme-BMX6/virtual/routeCheck.sh\"]\n"
				file.puts "set progBMX6#{node} [$node#{node} program-agent -command \"/proj/CONFINE/runme-BMX6/virtual/start_BMX6.sh\"]\n"

				file.puts "$nodeGroupInstall add $progInstall#{node}\n"
				file.puts "$nodeGroupInstallBMX6 add $progInstallBMX6#{node}\n"
    				file.puts "$nodeGroupWriteIPv6 add $progWriteIPv6#{node}\n"
				file.puts "$nodeGroupFilter add $progFilter#{node}\n"
				file.puts "$nodeGroupRouteCheck add $progRouteCheck#{node}\n"
    				file.puts "$nodeGroupBMX6 add $progBMX6#{node}\n"
				file.puts "\n"
			end

			# define the image of the nodes
			@nodes.each do |node|
				file.puts "tb-set-hardware $node#{node} pcvm\n"
				file.puts "tb-set-node-os $node#{node} OPENVZ-STD\n"
			end
			file.puts "\n"

			file.puts "set nodeMonitor [$ns node]\n"
			file.puts "tb-set-hardware $nodeMonitor pcvm\n"
			file.puts "tb-set-node-os $nodeMonitor OPENVZ-STD\n"

			file.puts "set progSetupEnv [$nodeMonitor program-agent -command \"/proj/CONFINE/runme-BMX6/virtual/setup_exp_env.sh\"]\n"
			file.puts "set progSetRouter [$nodeMonitor program-agent -command \"sudo /proj/CONFINE/runme-BMX6/virtual/setRouter.sh\"]\n"
			file.puts "set progFailPass [$nodeMonitor program-agent -command \"sudo /proj/CONFINE/runme-BMX6/virtual/failpass.sh #{@nodes.length}\"]\n"
			file.puts "set progStartTcpdump [$nodeMonitor program-agent -command \"/proj/CONFINE/runme-BMX6/virtual/start_tcpdump.sh\"]\n"
			file.puts "set progIntervalLog [$nodeMonitor program-agent -command \"/proj/CONFINE/runme-BMX6/virtual/start_interval_logging.sh\"]\n"
			file.puts "set progStopTcpdump [$nodeMonitor program-agent -command \"/proj/CONFINE/runme-BMX6/virtual/stop_tcpdump.sh\"]\n"
			
			file.puts "$monitorSetupEnv add $progSetupEnv\n"
			file.puts "$monitorSetRouter add $progSetRouter\n"
			file.puts "$monitorFailPass add $progFailPass\n"
			file.puts "$monitorStartTcpdump add $progStartTcpdump\n"
			file.puts "$monitorIntervalLog add $progIntervalLog\n"
    			file.puts "$monitorStopTcpdump add $progStopTcpdump\n"
			file.puts "append lanstr \"$nodeMonitor \"\n"
			file.puts "\n"

			file.puts "set nodePhysical [$ns node]\n"
			file.puts "tb-set-node-os $nodePhysical UBUNTU12-64-STD\n"
			file.puts "append lanstr \"$nodePhysical \"\n"
			file.puts "\n"

			file.puts "set big-lan [$ns make-lan \"$lanstr\" 1000Mb 20ms]\n"
			file.puts "\n"

			file.puts "$ns at 30 \"$monitorSetupEnv start\"\n"
			file.puts "$ns at 40 \"$monitorSetRouter start\"\n"
			file.puts "$ns at 50 \"$nodeGroupInstall start\"\n"
			file.puts "$ns at 55 \"$nodeGroupInstallBMX6 start\"\n"
			file.puts "$ns at 180 \"$nodeGroupWriteIPv6 start\"\n"
			file.puts "$ns at 230 \"$monitorFailPass start\"\n"
			file.puts "$ns at 240 \"$nodeGroupFilter start\"\n"
			file.puts "$ns at 290 \"$nodeGroupRouteCheck start\"\n"
			file.puts "$ns at 300 \"$monitorStartTcpdump start\"\n"
			file.puts "$ns at 318 \"$monitorIntervalLog start\"\n"
			file.puts "$ns at 320 \"$nodeGroupBMX6 start\"\n"
			file.puts "$ns at 500 \"$monitorStopTcpdump start\"\n"
			
			file.puts "# $ns at 540.0 \"$ns swapout\"\n"

			file.puts "$ns run"
		end
	end

		# Creates NS experiment file out of @nodes and @links extracted from the topology
	def createVirtualBigLanOLSRd(suffix="VirtualBigLanOLSRd")
		t = Time.now
		topologyName = "#{t.strftime("%Y-%m-%d-%H-%M-%S")}-#{suffix}"
		FileUtils.mkdir topologyName
		createFilterFiles topologyName
		# Create a new file and write to it
		
		filename = "#{topologyName}/#{topologyName}.ns"
		File.open(filename, 'w') do |file|  
  			# use "\n" for two lines of text  
  			file.puts "set ns [new Simulator]\n"			
        		file.puts "source tb_compat.tcl\n\n"

			file.puts "set nodeGroupInstall [$ns event-group]\n"
			file.puts "set nodeGroupSetIPv6 [$ns event-group]\n"
			file.puts "set nodeGroupWriteIPv6 [$ns event-group]\n"
			file.puts "set nodeGroupFilter [$ns event-group]\n"
			file.puts "set nodeGroupRouteCheck [$ns event-group]\n"
			file.puts "set nodeGroupInstallOLSRd [$ns event-group]\n"
			file.puts "set nodeGroupOLSRd [$ns event-group]\n"

			file.puts "set monitorSetupEnv [$ns event-group]\n"
			file.puts "set monitorSetRouter [$ns event-group]\n"
			file.puts "set monitorFailPass [$ns event-group]\n"
			file.puts "set monitorStartTcpdump [$ns event-group]\n"
			file.puts "set monitorStopTcpdump [$ns event-group]\n"
			file.puts "set monitorIntervalLog [$ns event-group]\n\n"
			
			# define the nodes
			@nodes.each do |node|
				file.puts "set node#{node} [$ns node]\n"
				# Automatically place BMX6 on the node (in dir /usr/local/src).
				file.puts "tb-set-node-tarfiles $node#{node} /usr/local/src/ /proj/CONFINE/tarfiles/olsrd-0.6.5.2.tar.gz"
				file.puts "append lanstr \"$node#{node} \"\n"

				file.puts "set progInstall#{node} [$node#{node} program-agent -command \"sudo /proj/CONFINE/runme-OLSR/virtual/install_ip6tables.sh\"]\n"
				file.puts "set progInstallOLSRd#{node} [$node#{node} program-agent -command \"/proj/CONFINE/runme-OLSR/virtual/install_OLSR.sh\"]\n"
				file.puts "set progSetIPv6#{node} [$node#{node} program-agent -command \"/proj/CONFINE/runme-OLSR/virtual/setIPv6.sh\"]\n"
				file.puts "set progWriteIPv6#{node} [$node#{node} program-agent -command \"/proj/CONFINE/runme-OLSR/virtual/ipv6tofile.sh\"]\n"
				file.puts "set progFilter#{node} [$node#{node} program-agent -command \"/proj/CONFINE/runme-OLSR/virtual/filter_ip6tables.sh\"]\n"
				file.puts "set progRouteCheck#{node} [$node#{node} program-agent -command \"/proj/CONFINE/runme-OLSR/virtual/routeCheck.sh\"]\n"
				file.puts "set progOLSRd#{node} [$node#{node} program-agent -command \"/proj/CONFINE/runme-OLSR/virtual/start_OLSR.sh\"]\n"

				file.puts "$nodeGroupInstall add $progInstall#{node}\n"
				file.puts "$nodeGroupInstallOLSRd add $progInstallOLSRd#{node}\n"
				file.puts "$nodeGroupSetIPv6 add $progSetIPv6#{node}\n"
    				file.puts "$nodeGroupWriteIPv6 add $progWriteIPv6#{node}\n"
				file.puts "$nodeGroupFilter add $progFilter#{node}\n"
				file.puts "$nodeGroupRouteCheck add $progRouteCheck#{node}\n"
    				file.puts "$nodeGroupOLSRd add $progOLSRd#{node}\n"
				file.puts "\n"
			end

			# define the image of the nodes
			@nodes.each do |node|
				file.puts "tb-set-hardware $node#{node} pcvm\n"
				file.puts "tb-set-node-os $node#{node} OPENVZ-STD\n"
			end
			file.puts "\n"

			file.puts "set nodeMonitor [$ns node]\n"
			file.puts "tb-set-hardware $nodeMonitor pcvm\n"
			file.puts "tb-set-node-os $nodeMonitor OPENVZ-STD\n"

			file.puts "set progSetupEnv [$nodeMonitor program-agent -command \"/proj/CONFINE/runme-OLSR/virtual/setup_exp_env.sh\"]\n"
			file.puts "set progSetRouter [$nodeMonitor program-agent -command \"sudo /proj/CONFINE/runme-OLSR/virtual/setRouter.sh\"]\n"			
			file.puts "set progFailPass [$nodeMonitor program-agent -command \"sudo /proj/CONFINE/runme-OLSR/virtual/failpass.sh #{@nodes.length}\"]\n"
			file.puts "set progStartTcpdump [$nodeMonitor program-agent -command \"/proj/CONFINE/runme-OLSR/virtual/start_tcpdump.sh\"]\n"
			file.puts "set progIntervalLog [$nodeMonitor program-agent -command \"/proj/CONFINE/runme-OLSR/virtual/start_interval_logging.sh\"]\n"
			file.puts "set progStopTcpdump [$nodeMonitor program-agent -command \"/proj/CONFINE/runme-OLSR/virtual/stop_tcpdump.sh\"]\n"
			file.puts "$monitorSetupEnv add $progSetupEnv\n"
			file.puts "$monitorSetRouter add $progSetRouter\n"
			file.puts "$monitorFailPass add $progFailPass\n"
			file.puts "$monitorStartTcpdump add $progStartTcpdump\n"
			file.puts "$monitorIntervalLog add $progIntervalLog\n"
    			file.puts "$monitorStopTcpdump add $progStopTcpdump\n"
			file.puts "append lanstr \"$nodeMonitor \"\n"
			file.puts "\n"

			file.puts "set nodePhysical [$ns node]\n"
			file.puts "tb-set-node-os $nodePhysical UBUNTU12-64-STD\n"
			file.puts "append lanstr \"$nodePhysical \"\n"
			file.puts "\n"

			file.puts "set big-lan [$ns make-lan \"$lanstr\" 1000Mb 20ms]\n"
			file.puts "\n"

			file.puts "$ns at 30 \"$monitorSetupEnv start\"\n"
			file.puts "$ns at 40 \"$monitorSetRouter start\"\n"
			file.puts "$ns at 50 \"$nodeGroupInstall start\"\n"
			file.puts "$ns at 55 \"$nodeGroupInstallOLSRd start\"\n"
			file.puts "$ns at 180 \"$nodeGroupSetIPv6 start\"\n"
			file.puts "$ns at 220 \"$nodeGroupWriteIPv6 start\"\n"
			file.puts "$ns at 260 \"$monitorFailPass start\"\n"
			file.puts "$ns at 280 \"$nodeGroupFilter start\"\n"
			file.puts "$ns at 310 \"$nodeGroupRouteCheck start\"\n"
			file.puts "$ns at 320 \"$monitorStartTcpdump start\"\n"
			file.puts "$ns at 338 \"$monitorIntervalLog start\"\n"
			file.puts "$ns at 340 \"$nodeGroupOLSRd start\"\n"
			file.puts "$ns at 540 \"$monitorStopTcpdump start\"\n"
			
			file.puts "# $ns at 540.0 \"$ns swapout\"\n"

			file.puts "$ns run"
		end 
	end
end

nr_of_nodes = Integer(ARGV[0])
type = String(ARGV[1])
ccnml = CNML.new("cnml/baixpenedes.xml", nr_of_nodes)
if (type == "bmx")
	ccnml.createTopology 'bmx'
elsif (type == "olsr")
	ccnml.createTopology 'olsr'
else
	ccnml.createTopology
end
