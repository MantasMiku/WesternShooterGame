extends Control
## Server browser screen: lists every running game (online via the master server + LAN),
## with filters, sorting by column and ping. Double-click or JOIN to play.
##
## Where it lives: it is a panel inside main_menu.tscn. The main menu gives it a `service`
## (Scripts/Network/server_browser_service.gd) and calls open().
## Data it reads: service.servers (a Dictionary of server info) and service.master_status.
## The service does the actual network work (asks the master server over HTTP and
## broadcasts on the LAN over UDP, then pings each server); this script only DISPLAYS the
## list and tells the menu which server the player picked. It runs only on this machine.

## The player chose a server. main_menu.gd listens and actually connects to it.
signal join_requested(address: String, port: int)
## The BACK button was pressed (the menu shows its main page again).
signal closed

const MODE_IDS := ["", "team_vs_team", "deathmatch", "wave_survival"]   # index = filter option
## Internal mode ids -> nice names shown in the list.
const MODE_NAMES := {team_vs_team = "Team vs Team", deathmatch = "Death Match", wave_survival = "Wave Survival"}
## Column titles of the Tree (the index of each one is its column number).
const COLUMNS := ["Server", "Mode", "Map", "Players", "Ping", "Where"]

## The list itself. A Tree with a hidden root works as a table with columns.
@onready var tree: Tree = %ServerTree
## Drop-down to show only one game mode (options match MODE_IDS).
@onready var mode_filter: OptionButton = %ModeFilter
## Toggle button: hide servers that are full.
@onready var hide_full: Button = %HideFull
@onready var refresh_button: Button = %RefreshButton
@onready var join_button: Button = %JoinButton
## Text line at the bottom: server counts, master server status, "Searching...".
@onready var status_label: Label = %BrowserStatus
## Text box with the master server URL, so players can point to a different one.
@onready var master_edit: LineEdit = %MasterEdit

var service: Node   ## server_browser_service.gd, set by the menu before showing
## Which column we sort by (3 = Players) and whether it's descending (biggest first).
var _sort_column := 3
var _sort_desc := true


## Sets up the Tree's columns and connects all buttons.
func _ready() -> void:
	tree.columns = COLUMNS.size()
	tree.column_titles_visible = true
	# Hidden root: every row is a direct child of an invisible root item, so it looks like a flat table.
	tree.hide_root = true
	tree.select_mode = Tree.SELECT_ROW
	for i in COLUMNS.size():
		tree.set_column_title(i, COLUMNS[i])
		# Only the first column (server name) stretches to take spare width.
		tree.set_column_expand(i, i == 0)
		tree.set_column_custom_minimum_width(i, [300, 250, 130, 120, 80, 110][i])
	# item_activated = double-click or Enter on a row.
	tree.item_activated.connect(_join_selected)
	tree.item_selected.connect(func(): join_button.disabled = false)
	tree.column_title_clicked.connect(_on_title_clicked)
	# Changing a filter just redraws the list from the data we already have (no new network request).
	# The lambdas ignore the signal's argument (_i, _on) because we don't need it.
	mode_filter.item_selected.connect(func(_i): _rebuild())
	hide_full.toggled.connect(func(_on): _rebuild())
	refresh_button.pressed.connect(refresh)
	join_button.pressed.connect(_join_selected)
	%BackButton.pressed.connect(func(): hide(); closed.emit())
	%SaveMaster.pressed.connect(_save_master)
	master_edit.text_submitted.connect(func(_t): _save_master())


## Shows the browser and starts searching. Called by the main menu.
func open() -> void:
	show()
	master_edit.text = service.master_url
	# Connect to the service only once (open() can be called many times).
	if !service.list_changed.is_connected(_rebuild):
		service.list_changed.connect(_rebuild)
		service.refresh_finished.connect(_on_refresh_finished)
	refresh()


## Asks the service to search again. Results arrive later through list_changed / refresh_finished.
func refresh() -> void:
	refresh_button.disabled = true
	status_label.text = "Searching..."
	service.refresh()


## Uses the typed master server URL and searches again.
func _save_master() -> void:
	service.set_master_url(master_edit.text)
	refresh()


## The search is done: re-enable the button and show the final list.
func _on_refresh_finished() -> void:
	refresh_button.disabled = false
	_rebuild()


## Clicking a column title sorts by it; clicking the same title again flips the order.
func _on_title_clicked(column: int, _mouse_button: int) -> void:
	if column == _sort_column: _sort_desc = !_sort_desc
	else:
		_sort_column = column
		_sort_desc = column == 3   # most players first by default
	_rebuild()


## Clears and refills the whole list: filter -> sort -> one row per server.
## Also keeps the selected server selected, and updates the status text.
func _rebuild() -> void:
	# Remember which server was selected (by id) so the selection survives the rebuild.
	var selected_id := ""
	if tree.get_selected(): selected_id = tree.get_selected().get_metadata(0).id
	tree.clear()
	var root := tree.create_item()
	var mode_id: String = MODE_IDS[mode_filter.selected]
	var rows: Array = service.servers.values().filter(func(s): return _passes_filter(s, mode_id))
	rows.sort_custom(_compare)

	for s in rows:
		var item := tree.create_item(root)
		# Store the whole server Dictionary on the row, so joining later can read address/port.
		item.set_metadata(0, s)
		var mode_text: String = MODE_NAMES.get(s.mode, s.mode)
		if s.sub_mode != "": mode_text += " - " + s.sub_mode
		item.set_text(0, s.name)
		item.set_text(1, mode_text)
		item.set_text(2, s.map)
		item.set_text(3, "%d / %d" % [s.players, s.max_players])
		# ping is -1 until the server has answered our ping.
		item.set_text(4, str(s.ping) if s.ping >= 0 else "-")
		item.set_text(5, s.source)
		for c in range(3, 6): item.set_text_alignment(c, HORIZONTAL_ALIGNMENT_CENTER)
		# Full servers are greyed out. Otherwise the ping is coloured green / yellow / red.
		if s.players >= s.max_players:
			for c in COLUMNS.size(): item.set_custom_color(c, Color(0.6, 0.5, 0.4))
		elif s.ping >= 0:
			item.set_custom_color(4, Color(0.5, 1, 0.5) if s.ping < 60 else (Color(1, 0.85, 0.4) if s.ping < 120 else Color(1, 0.45, 0.35)))
		if s.id == selected_id: item.select(0)
	join_button.disabled = tree.get_selected() == null

	# Status line, e.g. "3 servers (1 LAN, 2 online)   |   master server: online".
	var lan := rows.filter(func(s): return s.source == "LAN").size()
	var text := "%d server%s (%d LAN, %d online)" % [rows.size(), "" if rows.size() == 1 else "s", lan, rows.size() - lan]
	match service.master_status:
		"ok": text += "   |   master server: online"
		"": text += "   |   master server: checking..."
		# Anything else is an error message - LAN search still works without the master server.
		_: text += "   |   %s - showing LAN games only" % service.master_status
	if service.is_refreshing(): text = "Searching...   " + text
	status_label.text = text


## True if a server should be shown with the current filters.
func _passes_filter(s: Dictionary, mode_id: String) -> bool:
	if mode_id != "" and s.mode != mode_id: return false
	return !(hide_full.button_pressed and s.players >= s.max_players)


## Sort function for sort_custom: returns true if `a` should come before `b`.
func _compare(a: Dictionary, b: Dictionary) -> bool:
	# Pick the value to compare (the "key") based on the sort column.
	var ka
	var kb
	match _sort_column:
		0: ka = a.name.to_lower(); kb = b.name.to_lower()
		1: ka = a.mode; kb = b.mode
		2: ka = a.map; kb = b.map
		3: ka = a.players; kb = b.players
		# Unknown ping (-1) counts as huge, so those servers end up at the bottom when sorting by ping.
		4: ka = a.ping if a.ping >= 0 else 99999; kb = b.ping if b.ping >= 0 else 99999
		_: ka = a.source; kb = b.source
	# Ties are broken by name so the order doesn't jump around between rebuilds.
	if ka == kb: return a.name < b.name
	return ka > kb if _sort_desc else ka < kb


## Joins the selected server (JOIN button or double-click), unless it is full.
func _join_selected() -> void:
	var item := tree.get_selected()
	if item == null: return
	var s: Dictionary = item.get_metadata(0)
	if s.players >= s.max_players:
		status_label.text = "That server is full."
		return
	join_requested.emit(s.address, s.port)
