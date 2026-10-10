extends Node
## Runs on every game server (dedicated or a player hosting). Answers small UDP "who are you?"
## packets on game port + 100 with the server's info, so browsers can list it and measure ping.
## This is also how LAN games are found without the master server.
##
## Created by the level (multiplayer_test_scene.gd, _start_server_services) on the SERVER only;
## clients never run it. It is completely separate from the ENet game connection: it uses its
## own port, so answering queries never disturbs the match.
##
## The protocol (both sides in plain text):
##   asker  -> server:  "WSQ1" + token          e.g. "WSQ1123456789"
##   server -> asker:   JSON of the server info + {"echo": token}
## The asker (server_browser_service.gd) remembers when it sent each token, so when the answer
## with the same token comes back, "now - sent time" is the ping in milliseconds.

const NetConfig = preload("res://Scripts/Network/net_config.gd")

## Returns the info Dictionary to send back (set by the level).
## It's called again for every query, so the player count is always up to date.
var info_provider: Callable

# UDPServer works a bit like a TCP server for UDP: each new address that sends us a packet
# becomes its own PacketPeerUDP "connection" we can read from and reply to.
var _server := UDPServer.new()
var _peers: Array = []   # [{peer: PacketPeerUDP, last: float}]


## Starts listening on the query port for this game port. Returns false if the port is taken
## (the game still works, it just won't show up in LAN browsing).
func start(game_port: int) -> bool:
	var err := _server.listen(NetConfig.query_port(game_port))
	if err != OK:
		push_warning("Server query port %d unavailable - this server won't show up in LAN browsing." % NetConfig.query_port(game_port))
		return false
	return true


# Every frame: accept new askers, answer their packets, and forget quiet ones.
func _process(_delta: float) -> void:
	if !_server.is_listening(): return
	_server.poll()   # lets UDPServer read incoming packets and notice new senders
	var now := Time.get_ticks_msec() / 1000.0   # seconds since the game started
	while _server.is_connection_available():
		_peers.append({peer = _server.take_connection(), last = now})
	for p in _peers:
		var peer: PacketPeerUDP = p.peer
		while peer.get_available_packet_count() > 0:
			var msg := peer.get_packet().get_string_from_utf8()
			p.last = now
			# Only answer real queries (they start with the magic word).
			if msg.begins_with(NetConfig.QUERY_MAGIC) and info_provider.is_valid():
				var info: Dictionary = info_provider.call()
				info["echo"] = msg.substr(NetConfig.QUERY_MAGIC.length())   # lets the asker match reply -> request
				peer.put_packet(JSON.stringify(info).to_utf8_buffer())
	# UDP has no "disconnect", so drop askers we haven't heard from for 10 seconds.
	_peers = _peers.filter(func(p): return now - p.last < 10.0)


# Frees the port when the level closes (e.g. going back to the menu).
func _exit_tree() -> void:
	_server.stop()
